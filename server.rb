require 'octokit'
require 'json'
require 'sinatra/json'
require 'sinatra/base'
require 'faraday-http-cache'

# configuring cache for Octokit
stack = Faraday::RackBuilder.new do |builder|
  builder.use Faraday::HttpCache, serializer: Marshal, shared_cache: false
  builder.use Octokit::Response::RaiseError
  builder.adapter Faraday.default_adapter
end
Octokit.middleware = stack

class GHIssuesApp < Sinatra::Base

  configure do
    enable :sessions
    enable :logging
  end

  def authorized?
    session['access_token']
  end

  def authorize!
    session[:access_token] = ENV['GH_TOKEN']
  end

  before do 
    unless authorized?
      authorize!
    end
  end

  def gh
    Octokit::Client.new(access_token: session[:access_token], api_endpoint: "https://github.bus.zalan.do/api/v3")
  end

  get '/' do 
    redirect '/index.html'
  end

  get '/api/:org/issues' do 
    org = params[:org]
    milestone_title = params["milestone"]
    if params.key?('labels')
      labels = params["labels"].split(',')
    else
      labels = []
    end

    client = gh
    issues = client.repositories(org).map do |repo|
      begin
	milestone = client.milestones(repo.full_name).find{|m| m.title == milestone_title}
	if milestone
	  client.issues(repo.full_name, milestone: milestone.number)
	else
	  logger.info "No milestone found #{milestone_title} for #{repo.full_name}..."
	  []
	end
      rescue Octokit::NotFound => e 
	logger.info "No milestone found for #{milestone}: #{e}"
	[]
      end
    end.flatten!

    groups = labels.map{|e| [e, []]}.to_h
    issues.reduce(groups) do |acc, el|
      el.labels.map(&:name)
	.select{|lab| groups.key?(lab)}
	.each{|lab| acc[lab] << el.to_h}
      acc
    end

    json labels.map{|label| {label: label, items: groups[label]}}
  end

  get '/api/:org/milestones' do
    org = params[:org]
    client = gh
    milestones = client.repositories(org).map! do |repo|
      client.milestones(repo.full_name)
    end.flatten.uniq(&:title)

    json milestones.map(&:to_h)
  end

  post  '/api/:org/milestones' do
    org = params[:org]
    request.body.rewind
    data = JSON.parse request.body.read
    logger.info "creating milestone with data #{data}"
    client = gh
    createds = client.repositories(org).map do |repo|
      logger.info "creating milestone for #{repo.full_name}"
      begin
	gh.create_milestone(repo.full_name, data['title'], description: data['description'], due_on: data['due_on'])
      rescue Octokit::UnprocessableEntity => e
	logger.info "already exist for project #{repo.full_name} #{e}"
      end

    end

    status 201
    json createds.first if createds.first

  end
  
  run!
end 
