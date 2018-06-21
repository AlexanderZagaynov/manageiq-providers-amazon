# frozen_string_literal: true

require 'uri'
require 'json'
require 'base64'
require 'pathname'
require 'net/http'

class GithubFile
  API_HOST = 'api.github.com'
  API_HEADERS = { 'Accept' => 'application/vnd.github.v3+json' }.tap do |headers|
    if (api_token = ENV['GITHUB_API_TOKEN'])
      headers.merge!('Authorization' => "token #{api_token}")
    else
      warn 'No GitHub API key found in ENV, consider getting one at https://github.com/settings/tokens'
    end
  end.freeze

  cattr_accessor :logger, :instance_writer => false

  cattr_accessor :cache, :instance_writer => false do
    ActiveSupport::Cache::FileStore.new(
      Rails.root.join('tmp/aws_cache/products_data_collector'))
  end

  attr_reader *%i(repo_path file_path cache_dir)

  def initialize(repo_path, file_path, cache_dir: 'gh_data')
    @repo_path = repo_path
    @file_path = file_path
    @cache_dir = Rails.root.join('tmp', cache_dir)
  end

  def commits_uri
    @commits_uri ||= make_uri('commits',
                              :path => file_path,
                              :page => 1,
                              :per_page => 1)
  end

  def latest_sha
    @latest_sha ||= get_data(commits_uri)[0]['sha'].tap do |sha|
      logger.debug "Latest commit SHA of '#{file_path}' file is #{sha}"
    end
  end
  alias_method :file_sha, :latest_sha

  def content_uri
    @content_uri ||= make_uri("contents/#{file_path}", :ref => latest_sha)
  end

  def cache_file
    @cache_file ||= begin
      path = "#{repo_path.gsub('/','___')}___#{file_path.gsub('/','__')}"
      path = Pathname.new(path)
      cache_dir.join("#{path.basename}.#{file_sha}#{path.extname}")
    end
  end

  def content
    @content ||= begin
      if cache_file.file?
        logger.info "Using cached file #{cache_file}"
        cache_file.read
      else
        logger.info "Getting file #{repo_path} : #{file_path}"
        Base64.decode64(get_data(content_uri)['content']).tap do |data|
          cache_dir.mkpath
          cache_file.write(data)
        end
      end
    end
  end

  private

  def make_uri(uri_path, query_data)
    URI::HTTPS.build(
      :host  => API_HOST,
      :path  => "/repos/#{repo_path}/#{uri_path}",
      :query => query_data.to_query)
  end

  def make_request(uri)
    logger.info "Making request to #{uri}"
    response = Net::HTTP.start(uri.host, :use_ssl => true) do |http|
      http.get(uri.request_uri, API_HEADERS)
    end
    unless response.is_a?(Net::HTTPSuccess)
      if response.code_type.body_permitted?
        data = JSON.parse(response.body)
        error data['message'] if data.key?('message')
      end
      error "Error getting data from #{uri}"
      response.error!
    end
    response
  end

  def get_data(uri)
    JSON.parse(make_request(uri).body)
  end
end
