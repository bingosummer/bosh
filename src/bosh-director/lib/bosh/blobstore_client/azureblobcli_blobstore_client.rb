require 'securerandom'
require 'open3'
require 'json'

module Bosh::Blobstore
  class AzureblobcliBlobstoreClient < BaseClient

    EXIT_CODE_OBJECT_FOUND = 0
    EXIT_CODE_OBJECT_NOTFOUND = 3

    # Blobstore client for AzureBlob, using bosh-azureblobcli binary
    # @param [Hash] options AzureBlobconnection options
    # @option options [Symbol] bucket_name
    #   key that is applied before the object is sent to AzureBlob
    # @option options [Symbol, optional] storage_account_name
    # @option options [Symbol, optional] storage_account_access_key
    # @option options [Symbol] azureblobcli_path
    #   path to azureblobcli binary
    # @option options [Symbol, optional] azureblobcli_config_path
    #   path to store configuration files
    # @note If storage_account_name and storage_account_access_key are not present, the
    #   blobstore client operates in read only mode
    def initialize(options)
      super(options)

      @azureblobcli_path = @options.fetch(:azureblobcli_path)
      unless Kernel.system("#{@azureblobcli_path}", "--v", out: "/dev/null", err: "/dev/null")
        raise BlobstoreError, "Cannot find azureblobcli executable. Please specify azureblobcli_path parameter"
      end

      @azureblobcli_options = {
        container_name: @options[:bucket_name],
        credentials_source: @options.fetch(:credentials_source, 'static'),
        storage_account_name: @options[:storage_account_name],
        storage_account_access_key: @options[:storage_account_access_key],
      }

      @azureblobcli_options.reject! {|k,v| v.nil?}

      @config_file = write_config_file(@options.fetch(:azureblobcli_config_path, nil))
    end

    protected

    # @param [File] file file to store in AzureBlob
    def create_file(object_id, file)
      object_id ||= generate_object_id

      store_in_azureblob(file.path, full_oid_path(object_id))

      object_id
    end

    # @param [String] object_id object id to retrieve
    # @param [File] file file to store the retrived object in
    def get_file(object_id, file)
      begin
        out, err, status = Open3.capture3("#{@azureblobcli_path}", "-c", "#{@config_file}", "get", "#{object_id}", "#{file.path}")
      rescue Exception => e
        raise BlobstoreError, e.inspect
      end
      if !status.success?
        if err =~ /object doesn't exist/
          raise NotFound, "Blobstore object '#{object_id}' not found"
        end
        raise BlobstoreError, "Failed to download AzureBlob object, code #{status.exitstatus}, output: '#{out}', error: '#{err}'"
      end
    end

    # @param [String] object_id object id to delete
    def delete_object(object_id)
      begin
        out, err, status = Open3.capture3("#{@azureblobcli_path}", "-c", "#{@config_file}", "delete", "#{object_id}")
      rescue Exception => e
        raise BlobstoreError, e.inspect
      end
      raise BlobstoreError, "Failed to delete AzureBlob object, code #{status.exitstatus}, output: '#{out}', error: '#{err}'" unless status.success?
    end

    def object_exists?(object_id)
      begin
        out, err, status = Open3.capture3("#{@azureblobcli_path}", "-c", "#{@config_file}", "exists", "#{object_id}")
        if status.exitstatus == EXIT_CODE_OBJECT_FOUND
          return true
        end
        if status.exitstatus == EXIT_CODE_OBJECT_NOTFOUND
          return false
        end
      rescue Exception => e
        raise BlobstoreError, e.inspect
      end
      raise BlobstoreError, "Failed to check existence of AzureBlob object, code #{status.exitstatus}, output: '#{out}', error: '#{err}'" unless status.success?
    end

    # @param [String] path path to file which will be stored in AzureBlob
    # @param [String] oid object id
    # @return [void]
    def store_in_azureblob(path, oid)
      begin
        out, err, status = Open3.capture3("#{@azureblobcli_path}", "-c", "#{@config_file}", "put", "#{path}", "#{oid}")
      rescue Exception => e
        raise BlobstoreError, e.inspect
      end
      raise BlobstoreError, "Failed to create AzureBlob object, code #{status.exitstatus}, output: '#{out}', error: '#{err}'" unless status.success?
    end

    def full_oid_path(object_id)
       @options[:folder] ?  @options[:folder] + '/' + object_id : object_id
    end

    def write_config_file(config_file_dir = nil)
      config_file_dir = Dir::tmpdir unless config_file_dir
      Dir.mkdir(config_file_dir) unless File.exists?(config_file_dir)
      random_name = "azureblob_blobstore_config-#{SecureRandom.uuid}"
      config_file = File.join(config_file_dir, random_name)
      config_data = JSON.dump(@azureblobcli_options)

      File.open(config_file, 'w', 0600) { |file| file.write(config_data) }
      config_file
    end
  end
end
