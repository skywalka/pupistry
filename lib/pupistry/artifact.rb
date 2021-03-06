# rubocop:disable Style/Documentation, Style/GlobalVars
require 'rubygems'
require 'yaml'
require 'safe_yaml'
require 'time'
require 'digest'
require 'fileutils'
require 'base64'

module Pupistry
  # Pupistry::Artifact

  class Artifact
    # All the functions needed for manipulating the artifats
    attr_accessor :checksum

    def fetch_r10k
      $logger.info 'Using r10k utility to fetch the latest Puppet code'

      unless defined? $config['build']['puppetcode']
        $logger.fatal 'You must configure the build:puppetcode config option in settings.yaml'
        fail 'Invalid Configuration'
      end

      # https://github.com/puppetlabs/r10k
      #
      # r10k does a fantastic job with all the git stuff and we want to use it
      # to download the Puppet code from all the git modules (based on following
      # the master one provided), then we can steal the Puppet code from the
      # artifact generated.
      #
      # TODO: We should re-write this to hook directly into r10k's libraries,
      # given that both Pupistry and r10k are Ruby, presumably it should be
      # doable and much more polished approach. For now the MVP is to just run
      # it via system, pull requests/patches to fix very welcome!

      # Build the r10k config to instruct it to use our cache path for storing
      # it's data and exporting the finished result.
      $logger.debug 'Generating an r10k configuration file...'
      r10k_config = {
        'cachedir' => "#{$config['general']['app_cache']}/r10kcache",
        'sources'  => {
          'puppet' => {
            'remote'  => $config['build']['puppetcode'],
            'basedir' => $config['general']['app_cache'] + '/puppetcode'
          }
        }
      }

      begin
        File.open("#{$config['general']['app_cache']}/r10kconfig.yaml", 'w') do |fh|
          fh.write YAML.dump(r10k_config)
        end
      rescue StandardError => e
        $logger.fatal 'Unexpected error when trying to write the r10k configuration file'
        raise e
      end

      # Execute R10k with the provided configuration
      $logger.debug 'Executing r10k'

      if system "r10k deploy environment -c #{$config['general']['app_cache']}/r10kconfig.yaml -pv debug"
        $logger.info 'r10k run completed'
      else
        $logger.error 'r10k run failed, unable to generate artifact'
        fail 'r10k run did not complete, unable to generate artifact'
      end
    end

    def fetch_latest
      # Fetch the latest S3 YAML file and check the version metadata without writing
      # it to disk. Returns the version. Useful for quickly checking for updates :-)

      $logger.debug 'Checking latest artifact version...'

      s3        = Pupistry::StorageAWS.new 'agent'
      contents  = s3.download 'manifest.latest.yaml'

      if contents
        manifest = YAML.load(contents, safe: true, raise_on_unknown_tag: true)

        if defined? manifest['version']
          # We have a manifest version supplied, however since the manifest
          # isn't signed, there's risk of an exploited S3 bucket replacing
          # the version with injections designed to attack the shell commands
          # we call from Pupistry.
          #
          # Therefore we need to make sure the manifest version matches a
          # regex suitable for a checksum.

          if /^[A-Za-z0-9]{32}$/.match(manifest['version'])
            return manifest['version']
          else
            $logger.error 'Manifest version returned from S3 manifest.latest.yaml did not match expected regex of MD5.'
            $logger.error 'Possible bug or security incident, investigate with care!'
            $logger.error "Returned version string was: \"#{manifest['version']}\""
            exit 0
          end
        else
          return false
        end

      else
        # download did not work
        return false
      end
    end

    def fetch_current
      # Fetch the latest on-disk YAML file and check the version metadata, used
      # to determine the latest artifact that has not yet been pushed to S3.
      # Returns the version.

      # Read the symlink information to get the latest version
      if File.exist?($config['general']['app_cache'] + '/artifacts/manifest.latest.yaml')
        manifest    = YAML.load(File.open($config['general']['app_cache'] + '/artifacts/manifest.latest.yaml'), safe: true, raise_on_unknown_tag: true)
        @checksum   = manifest['version']
      else
        $logger.error 'No artifact has been built yet. You need to run pupistry build first?'
        return false
      end
    end

    def fetch_installed
      # Fetch the current version that is installed.

      # Make sure the Puppetcode install directory exists
      unless Dir.exist?($config['agent']['puppetcode'])
        $logger.warn "The destination path of #{$config['agent']['puppetcode']} does not appear to exist or is not readable"
        return false
      end

      # Look for a manifest file in the directory and read the version from it.
      if File.exist?($config['agent']['puppetcode'] + '/manifest.pupistry.yaml')
        manifest = YAML.load(File.open($config['agent']['puppetcode'] + '/manifest.pupistry.yaml'), safe: true, raise_on_unknown_tag: true)

        return manifest['version']
      else
        $logger.warn 'No current version installed'
        return false
      end
    end

    def fetch_artifact
      # Figure out which version to fetch (if not explicitly defined)
      if defined? @checksum
        $logger.debug "Downloading artifact version #{@checksum}"
      else
        @checksum = fetch_latest

        if defined? @checksum
          $logger.debug "Downloading latest artifact (#{@checksum})"
        else
          $logger.error 'There is not current artifact that can be fetched'
          return false
        end

      end

      # Make sure the download dir/cache exists
      FileUtils.mkdir_p $config['general']['app_cache'] + '/artifacts/' unless Dir.exist?($config['general']['app_cache'] + '/artifacts/')

      # Download files if they don't already exist
      if File.exist?($config['general']['app_cache'] + "/artifacts/manifest.#{@checksum}.yaml") &&
         File.exist?($config['general']['app_cache'] + "/artifacts/artifact.#{@checksum}.tar.gz")
        $logger.debug 'This artifact is already present, no download required.'
      else
        s3 = Pupistry::StorageAWS.new 'agent'
        s3.download "manifest.#{@checksum}.yaml", $config['general']['app_cache'] + "/artifacts/manifest.#{@checksum}.yaml"
        s3.download "artifact.#{@checksum}.tar.gz", $config['general']['app_cache'] + "/artifacts/artifact.#{@checksum}.tar.gz"
      end
    end

    def hieracrypt_encrypt
      # Stub function, since HieraCrypt has no association with the actual
      # artifact file, but rather the post-r10k checked data, it could be
      # invoked directly. However it's worth wrapping here incase we ever
      # do change this behavior.

      Pupistry::HieraCrypt.encrypt_hieradata

    end

    def hieracrypt_decrypt
      # Decrypt any encrypted Hieradata inside the currently unpacked artifact
      # before it gets copied to the installation location.

      if defined? @checksum
        Pupistry::HieraCrypt.decrypt_hieradata $config['general']['app_cache'] + "/artifacts/unpacked.#{@checksum}/puppetcode"
      else
        $logger.warn "Tried to request hieracrypt_decrypt on no artifact."
      end

    end
    def push_artifact
      # The push step involves 2 steps:
      # 1. GPG sign the artifact and write it into the manifest file
      # 2. Upload the manifest and archive files to S3.
      # 3. Upload a copy as the "latest" manifest file which will be hit by clients.

      # Determine which version we are uploading. Either one specifically
      # selected, otherwise find the latest one to push

      if defined? @checksum
        $logger.info "Uploading artifact version #{@checksum}."
      else
        @checksum = fetch_current

        if @checksum
          $logger.info "Uploading artifact version latest (#{@checksum})"
        else
          # If there is no current version, we can't do much....
          exit 0
        end
      end

      # Do we even need to upload? If nothing has changed....
      if @checksum == fetch_latest
        $logger.error "You've already pushed this artifact version, nothing to do."
        exit 0
      end

      # Make sure the files actually exist...
      unless File.exist?($config['general']['app_cache'] + "/artifacts/manifest.#{@checksum}.yaml")
        $logger.error "The files expected for #{@checksum} do not appear to exist or are not readable"
        fail 'Fatal unexpected error'
      end

      unless File.exist?($config['general']['app_cache'] + "/artifacts/artifact.#{@checksum}.tar.gz")
        $logger.error "The files expected for #{@checksum} do not appear to exist or are not readable"
        fail 'Fatal unexpected error'
      end

      # GPG sign the files
      if $config['general']['gpg_disable'] == true
        $logger.warn 'You have GPG signing *disabled*, whilst not critical it does weaken your security.'
        $logger.warn 'Skipping signing step...'
      else

        gpgsig = Pupistry::GPG.new @checksum

        # Sign the artifact
        unless gpgsig.artifact_sign
          $logger.fatal 'Unable to proceed with an unsigned artifact'
          exit 0
        end

        # Verify the signature - we want to make sure what we've just signed
        # can actually be validated properly :-)
        unless gpgsig.artifact_verify
          $logger.fatal 'Whilst a signature was generated, it was unable to be validated. This would suggest a bug of some kind.'
          exit 0
        end

        # Save the signature to the manifest
        unless gpgsig.signature_save
          $logger.fatal 'Unable to write the signature into the manifest file for the artifact.'
          exit 0
        end

      end

      # Upload the artifact & manifests to S3. We also make an additional copy
      # as the "latest" file which will be downloaded by all the agents checking
      # for new updates.

      s3 = Pupistry::StorageAWS.new 'build'
      s3.upload $config['general']['app_cache'] + "/artifacts/artifact.#{@checksum}.tar.gz", "artifact.#{@checksum}.tar.gz"
      s3.upload $config['general']['app_cache'] + "/artifacts/manifest.#{@checksum}.yaml", "manifest.#{@checksum}.yaml"
      s3.upload $config['general']['app_cache'] + "/artifacts/manifest.#{@checksum}.yaml", 'manifest.latest.yaml'

      # Test a read of the manifest, we do this to make sure the S3 ACLs setup
      # allow downloading of the uploaded files - helps avoid user headaches if
      # they misconfigure and then blindly trust their bootstrap config.
      #
      # Only worth doing this step if they've explicitly set their AWS IAM credentials
      # for the agent, which should be everyone except for IAM role users.

      if $config['agent']['access_key_id']
        fetch_artifact
      else
        $logger.warn "The agent's AWS credentials are unset on this machine, unable to do download test to check permissions for you."
        $logger.warn "Assuming you know what you're doing, please set if unsure."
      end

      $logger.info "Upload of artifact version #{@checksum} completed and is now latest"
    end

    def build_artifact
      # r10k has done all the heavy lifting for us, we just need to generate a
      # tarball from the app_cache /puppetcode directory. There are some Ruby
      # native libraries, but really we might as well just use the native tools
      # since we don't want to do anything clever like in-memory assembly of
      # the file. Like r10k, if you want to convert to a nicely polished native
      # Ruby solution, patches welcome.

      $logger.info 'Creating artifact...'

      Dir.chdir($config['general']['app_cache']) do
        # Make sure there is a directory to write artifacts into
        FileUtils.mkdir_p('artifacts')

        # Build the tar file - we delibertly don't compress in a single step
        # so that we can grab the checksum, since checksum will always differ
        # post-compression.

        tar = Pupistry::Config.which_tar
        $logger.debug "Using tar at #{tar}"

        tar += " -c"
        tar += " --exclude '.git'"
        if Pupistry::HieraCrypt.is_enabled?
          # We want to exclude unencrypted hieradata (duh security) and also the node files (which aren't needed)
          tar += " --exclude 'hieradata'"
          tar += " --exclude 'hieracrypt/nodes'"
        else
          # Hieracrypt is disable, exclude any old out of date encrypted files
          tar += " --exclude 'hieracrypt/encrypted'"
        end
        tar += " -f artifacts/artifact.temp.tar puppetcode/*"

        unless system tar
          $logger.error 'Unable to create tarball'
          fail 'An unexpected error occured when executing tar'
        end

        # The checksum is important, we use it as our version for each artifact
        # so we can tell them apart in a unique way.
        @checksum = Digest::MD5.file($config['general']['app_cache'] + '/artifacts/artifact.temp.tar').hexdigest

        # Now we have the checksum, check if it's the same as any existing
        # artifacts. If so, drop out here, good to give feedback to the user
        # if nothing has changed since it's easy to forget to git push a single
        # module/change.

        if File.exist?($config['general']['app_cache'] + "/artifacts/manifest.#{@checksum}.yaml")
          $logger.error "This artifact version (#{@checksum}) has already been built, nothing todo."
          $logger.error "Did you remember to \"git push\" your module changes?"

          # TODO: Unfortunatly Hieracrypt breaks this, since the encrypted Hieradata is different
          # on every run, which results in the checksum always being different even if nothing in
          # the repo itself has changed. We need a proper fix for this at some stage, for now it's
          # covered in the readme notes for HieraCrypt as a flaw.

          # Cleanup temp file
          FileUtils.rm($config['general']['app_cache'] + '/artifacts/artifact.temp.tar')
          exit 0
        end

        # Compress the artifact now that we have taken it's checksum
        $logger.info 'Compressing artifact...'

        if system 'gzip artifacts/artifact.temp.tar'
        else
          $logger.error 'An unexpected error occured during compression of the artifact'
          fail 'An unexpected error occured during compression of the artifact'
        end
      end

      # We have the checksum, so we can now rename the artifact file
      FileUtils.mv($config['general']['app_cache'] + '/artifacts/artifact.temp.tar.gz',
                   $config['general']['app_cache'] + "/artifacts/artifact.#{@checksum}.tar.gz")

      $logger.info 'Building manifest information for artifact...'

      # Create the manifest file, this is used by clients for pulling details about
      # the latest artifacts. We don't GPG sign here, but we do put in a placeholder.
      manifest = {
        'version'   => @checksum,
        'date'      => Time.new.inspect,
        'builduser' => ENV['USER'] || 'unlabled',
        'gpgsig'    => 'unsigned'
      }

      begin
        File.open("#{$config['general']['app_cache']}/artifacts/manifest.#{@checksum}.yaml", 'w') do |fh|
          fh.write YAML.dump(manifest)
        end
      rescue StandardError => e
        $logger.fatal 'Unexpected error when trying to write the manifest file'
        raise e
      end

      # This is the latest artifact, create some symlinks pointing the latest to it
      begin
        FileUtils.ln_s("manifest.#{@checksum}.yaml",
                       "#{$config['general']['app_cache']}/artifacts/manifest.latest.yaml",
                       force: true)
        FileUtils.ln_s("artifact.#{@checksum}.tar.gz",
                       "#{$config['general']['app_cache']}/artifacts/artifact.latest.tar.gz",
                       force: true)
      rescue StandardError => e
        $logger.fatal 'Something weird went really wrong trying to symlink the latest artifacts'
        raise e
      end

      $logger.info "New artifact version #{@checksum} ready for pushing"
    end

    def unpack
      # Unpack the currently selected artifact to the archives directory.

      # An application version must be specified
      fail 'Application bug, trying to unpack no artifact' unless defined? @checksum

      # Make sure the files actually exist...
      unless File.exist?($config['general']['app_cache'] + "/artifacts/manifest.#{@checksum}.yaml")
        $logger.error "The files expected for #{@checksum} do not appear to exist or are not readable"
        fail 'Fatal unexpected error'
      end

      unless File.exist?($config['general']['app_cache'] + "/artifacts/artifact.#{@checksum}.tar.gz")
        $logger.error "The files expected for #{@checksum} do not appear to exist or are not readable"
        fail 'Fatal unexpected error'
      end

      # Clean up an existing unpacked copy - in *theory* it should be same, but
      # a mistake like running out of disk could have left it in an unclean state
      # so let's make sure it's gone
      clean_unpack

      # Unpack the archive file
      FileUtils.mkdir_p($config['general']['app_cache'] + "/artifacts/unpacked.#{@checksum}")
      Dir.chdir($config['general']['app_cache'] + "/artifacts/unpacked.#{@checksum}") do
        tar = Pupistry::Config.which_tar
        $logger.debug "Using tar at #{tar}"

        if system "#{tar} -xzf ../artifact.#{@checksum}.tar.gz"
          $logger.debug "Successfully unpacked artifact #{@checksum}"
        else
          $logger.error "Unable to unpack artifact files to #{Dir.pwd}"
          fail 'An unexpected error occured when executing tar'
        end
      end
    end

    def install
      # Copy the unpacked artifact into the agent's configured location. Generally all the
      # heavy lifting is done by fetch_latest and unpack methods.

      # An application version must be specified
      fail 'Application bug, trying to install no artifact' unless defined? @checksum

      # Validate the artifact if GPG is enabled.
      if $config['general']['gpg_disable'] == true
        $logger.warn 'You have GPG validation *disabled*, whilst not critical it does weaken your security.'
        $logger.warn 'Skipping validation step...'
      else

        gpgsig = Pupistry::GPG.new @checksum

        unless gpgsig.artifact_verify
          $logger.fatal 'The GPG signature could not be validated for the artifact. This could be a bug, a file corruption or a POSSIBLE SECURITY ISSUE such as maliciously modified content.'
          fail 'Fatal unexpected error'
        end

      end

      # Make sure the artifact has been unpacked
      unless Dir.exist?($config['general']['app_cache'] + "/artifacts/unpacked.#{@checksum}")
        $logger.error "The unpacked directory expected for #{@checksum} does not appear to exist or is not readable"
        fail 'Fatal unexpected error'
      end

      # Purge any currently installed files in the directory. See clean_install
      # TODO: notes for how this could be improved.
      $logger.error 'Installation not proceeding due to issues cleaning/prepping destination dir' unless clean_install

      # Make sure the destination directory exists
      unless Dir.exist?($config['agent']['puppetcode'])
        $logger.error "The destination path of #{$config['agent']['puppetcode']} does not appear to exist or is not readable"
        fail 'Fatal unexpected error'
      end

      # Clone unpacked contents to the installation directory
      begin
        FileUtils.cp_r $config['general']['app_cache'] + "/artifacts/unpacked.#{@checksum}/puppetcode/.", $config['agent']['puppetcode']
        FileUtils.cp $config['general']['app_cache'] + "/artifacts/manifest.#{@checksum}.yaml", $config['agent']['puppetcode'] + '/manifest.pupistry.yaml'
        return true
      rescue
        $logger.fatal "An unexpected error occured when copying the unpacked artifact to #{$config['agent']['puppetcode']}"
        raise e
      end
    end

    def clean_install
      # Cleanup the destination installation directory before we unpack the artifact
      # into it, otherwise long term we will end up with old deprecated files hanging
      # around.
      #
      # TODO: Do this smarter, we should track what files we drop in, and then remove
      # any that weren't touched. Need to avoid rsync and stick with native to make
      # support easier for weird/minimilistic distributions.

      if defined? $config['agent']['puppetcode'] # rubocop:disable Style/GuardClause
        if $config['agent']['puppetcode'].empty?
          $logger.error "You must configure a location for the agent's Puppet code to be deployed to"
          return false
        else
          $logger.debug "Cleaning up #{$config['agent']['puppetcode']} directory"

          if Dir.exist?($config['agent']['puppetcode'])
            FileUtils.rm_r Dir.glob($config['agent']['puppetcode'] + '/*'), secure: true
          else
            FileUtils.mkdir_p $config['agent']['puppetcode']
            FileUtils.chmod(0700, $config['agent']['puppetcode'])
          end

          return true
        end
      end
    end

    def clean_unpack
      # Cleanup/remove any unpacked archive directories. Requires that the
      # checksum be set to the version to be purged.

      fail 'Application bug, trying to unpack no artifact' unless defined? @checksum

      if Dir.exist?($config['general']['app_cache'] + "/artifacts/unpacked.#{@checksum}/")
        $logger.debug "Cleaning up #{$config['general']['app_cache']}/artifacts/unpacked.#{@checksum}..."
        FileUtils.rm_r $config['general']['app_cache'] + "/artifacts/unpacked.#{@checksum}", secure: true
        return true
      else
        $logger.debug 'Nothing to cleanup (selected artifact is not currently unpacked)'
        return true
      end

      false
    end
  end
end

# vim:shiftwidth=2:tabstop=2:softtabstop=2:expandtab:smartindent
