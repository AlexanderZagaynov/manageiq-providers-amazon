# frozen_string_literal: true

require 'json'
require_relative 'github_file'

class AwsApiInfo
  REPO_PATH = 'aws/aws-sdk-ruby'

  API_HOST = 'api.github.com'

  API_HEADERS = { 'Accept' => 'application/vnd.github.v3+json' }.tap do |headers|
    if (api_token = ENV['GITHUB_API_TOKEN'])
      headers.merge!('Authorization' => "token #{api_token}")
    else
      logger.warn 'No GitHub API key found in ENV, consider getting one at https://github.com/settings/tokens'
    end
  end.freeze

  attr_reader :service_name

  def initialize(service_name)
    @service_name = service_name
  end

  def services_data
    @services_data ||= get_data('services.json')
  end

  def api_data
    @api_data ||= get_data(models_path)
  end

  private

  def get_data(file_path)
    gh_file = GithubFile.new(REPO_PATH, file_path)
    JSON.parse(gh_file.content)
  end

  def models_path
    @models_path ||= "apis/#{services_data[service_name]['models']}/api-2.json"
  end
end
