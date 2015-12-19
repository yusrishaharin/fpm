require "erb"
require "fpm/namespace"
require "fpm/package"
require "fpm/errors"
require "fpm/util"
require "backports"
require "fileutils"
require "digest"

# Support for debian packages (.deb files)
#
# This class supports both input and output of packages.
class FPM::Package::APK< FPM::Package

  # Map of what scripts are named.
  SCRIPT_MAP = {
    :before_install     => "pre-install",
    :after_install      => "post-install",
    :before_remove      => "pre-deinstall",
    :after_remove       => "post-deinstall",
  } unless defined?(SCRIPT_MAP)

  # The list of supported compression types. Default is gz (gzip)
  COMPRESSION_TYPES = [ "gz" ]

  private

  # Get the name of this package. See also FPM::Package#name
  #
  # This accessor actually modifies the name if it has some invalid or unwise
  # characters.
  def name
    if @name =~ /[A-Z]/
      logger.warn("apk packages should not have uppercase characters in their names")
      @name = @name.downcase
    end

    if @name.include?("_")
      logger.warn("apk packages should not include underscores")
      @name = @name.gsub(/[_]/, "-")
    end

    if @name.include?(" ")
      logger.warn("apk packages should not contain spaces")
      @name = @name.gsub(/[ ]/, "-")
    end

    return @name
  end # def name

  def prefix
    return (attributes[:prefix] or "/")
  end # def prefix

  def input(input_path)
    extract_info(input_path)
    extract_files(input_path)
  end # def input

  def extract_info(package)

    logger.error("Extraction is not yet implemented")
  end # def extract_info

  def extract_files(package)

    # unpack the data.tar.{gz,bz2,xz} from the deb package into staging_path
    safesystem("ar p #{package} data.tar.gz " \
               "| tar gz -xf - -C #{staging_path}")
  end # def extract_files

  def output(output_path)

    output_check(output_path)

    control_path = build_path("control")
    controltar_path = build_path("control.tar")
    datatar_path = build_path("data.tar")

    FileUtils.mkdir(control_path)

    # data tar.
    tar_path(staging_path(""), datatar_path)

    # control tar.
    begin
      write_pkginfo(control_path)
      write_control_scripts(control_path)
      tar_path(control_path, controltar_path)
    ensure
      FileUtils.rm_r(control_path)
    end

    # concatenate the two into a real apk.
    begin

      # cut end-of-tar record from control tar
      cut_tar_record(controltar_path)

      # calculate/rewrite sha1 hashes for data tar
      hash_datatar(datatar_path)

      # concatenate the two into the final apk
      concat_tars(controltar_path, datatar_path, output_path)
    ensure
      logger.warn("apk output to is not implemented")
      `rm -rf /tmp/apkfpm`
      `cp -r #{build_path("")} /tmp/apkfpm`
    end
  end

  def write_pkginfo(base_path)

    path = "#{base_path}/.PKGINFO"

    pkginfo_io = StringIO::new
    package_version = to_s("FULLVERSION")

    pkginfo_io << "pkgname = #{@name}\n"
    pkginfo_io << "pkgver = #{package_version}\n"

    File.write(path, pkginfo_io.string)
  end

  # Writes each control script from template into the build path,
  # in the folder given by [base_path]
  def write_control_scripts(base_path)

    scripts =
    [
      "pre-install",
      "post-install",
      "pre-deinstall",
      "post-deinstall",
      "pre-upgrade",
      "post-upgrade"
    ]

    scripts.each do |path|

      script_path = "#{base_path}/#{path}"
      File.write(script_path, template("apk/#{path}").result(binding))
    end
  end

  # Removes the end-of-tar records from the given [target_path].
  # End of tar records are two contiguous empty tar records at the end of the file
  # Taken together, they comprise 1k of null data.
  def cut_tar_record(target_path)

    record_length = 0
    contiguous_records = 0
    current_position = 0
    desired_tar_length = 0

    # Scan to find the location of the two contiguous null records
    open(target_path, "rb") do |file|

      until(contiguous_records == 2)

        # skip to header length
        file.read(124)

        ascii_length = file.read(12)
        if(file.eof?())
          raise StandardError.new("Invalid tar stream, eof before end-of-tar record")
        end

        record_length = ascii_length.to_i(8)
        logger.info("Record length: #{ascii_length} (#{record_length}), current position: #{(124 + current_position).to_s(16)}")

        if(record_length == 0)
          contiguous_records += 1
        else
          # If there was a previous null tar, add its header length too.
          if(contiguous_records != 0)
            desired_tar_length += 512
          end

          desired_tar_length += 512

          # tarballs work in 512-byte blocks, round up to the nearest block.
          if(record_length % 512 != 0)
            record_length += (512 * (1 - (record_length / 512.0))).round
          end
          current_position += record_length

          # reset, add length.
          contiguous_records = 0
          desired_tar_length += record_length
        end

        # finish off the read of the header length
        file.read(376)

        # skip content of record
        file.read(record_length)
      end
    end

    # Truncate file
    if(desired_tar_length <= 0)
      raise StandardError.new("Unable to trim apk control tar")
    end

    logger.info("Truncating '#{target_path}' to #{desired_tar_length}")
    File.truncate(target_path, desired_tar_length)
  end

  # Rewrites the tar file located at the given [target_tar_path]
  # to have its file headers use a sha1 checksum.
  def hash_datatar(target_tar_path)

  end

  # Concatenates the given [apath] and [bpath] into the given [target_path]
  def concat_tars(apath, bpath, target_path)

    target_file = open(target_path, "wb")

    open(apath, "rb") do |file|
      until(file.eof?())
        target_file.write(file.read(4096))
      end
    end
    open(bpath, "rb") do |file|
      until(file.eof?())
        target_file.write(file.read(4096))
      end
    end
  end

  # Tars the current contents of the given [path] to the given [target_path].
  def tar_path(path, target_path)

    args =
    [
      tar_cmd,
      "-C",
      path,
      "-cf",
      target_path,
      "--owner=0",
      "--group=0",
      "--numeric-owner",
      "."
    ]

    safesystem(*args)
  end

  def to_s(format=nil)
    return super("NAME_FULLVERSION_ARCH.TYPE") if format.nil?
    return super(format)
  end

  public(:input, :output, :architecture, :name, :prefix, :converted_from, :to_s)
end
