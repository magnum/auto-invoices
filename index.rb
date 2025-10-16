require 'rubygems'
require 'webrick'

require './oauth' # importing the class created in the next tab
#require './quickstart' # importing the class created in the previous steps

if $0 == __FILE__ then
  server = WEBrick::HTTPServer.new(:Port => 3000)
  #server.mount "/quickstart", QuickStart # route that refers to the QuickStary class in the imported quickstart.rb file
  server.mount "/oauth", Oauth  # route that refers to the Oauth class in the imported oauth.rb file
  trap "INT" do server.shutdown end
  server.start
end