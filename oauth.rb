require 'dotenv'
Dotenv.load()
require 'rubygems'
require 'webrick'
require 'json'
require 'fattureincloud_ruby_sdk'

class Oauth < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(request, response)
    oauth = FattureInCloud_Ruby_Sdk::OAuth2AuthorizationCodeManager.new(
        ENV['FATTUREINCLOUD_CLIENT_ID'], 
        ENV['FATTUREINCLOUD_CLIENT_SECRET'], 
        'http://localhost:3000/oauth'
    )
    if !request.request_uri.query.nil?
      url_obj = URI.decode_www_form(request.request_uri.query).to_h
      if !url_obj['code'].nil?
        token = oauth.fetch_token(url_obj['code'])
        File.open('./token.json', 'w') do |file|
          file.write({"access_token" => token.access_token}.to_json) # saving the oAuth access token in the token.json file
        end
        body = 'Token saved succesfully in ./token.json'
      else
        redirect(response, oauth)
      end
    else redirect(response, oauth)
    end

    response.status = 200
    response['Content-Type'] = 'text/html'
    response.body = body
  end

  def redirect(response, oauth)
    # scopes https://github.com/fattureincloud/fattureincloud-ruby-sdk/blob/a8f115b44e267d3c225ae893968e3b70d89d4f9f/lib/fattureincloud_ruby_sdk/oauth2/scope.rb#L11
    url = oauth.get_authorization_url([
        FattureInCloud_Ruby_Sdk::Scope::ENTITY_SUPPLIERS_READ,
        FattureInCloud_Ruby_Sdk::Scope::ISSUED_DOCUMENTS_SELF_INVOICES_ALL
    ], 'EXAMPLE_STATE')
    response.set_redirect(WEBrick::HTTPStatus::TemporaryRedirect, url)
  end
end

if $PROGRAM_NAME == __FILE__
  server = WEBrick::HTTPServer.new(Port: 3000)
  server.mount '/oauth', Oauth
  trap 'INT' do server.shutdown end
  server.start
end