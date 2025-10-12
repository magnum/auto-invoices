require 'fattureincloud_ruby_sdk'

class QuickStart < WEBrick::HTTPServlet::AbstractServlet

  def do_GET(request, response)

    # setup authorization
    FattureInCloud_Ruby_Sdk.configure do |config|
    # Configure OAuth2 access token for authorization: OAuth2AuthenticationCodeFlow
    config.access_token = retrieve_token_from_file()
    end

    # Retrieve the first company id
    user_api_instance = FattureInCloud_Ruby_Sdk::UserApi.new
    user_companies_response = user_api_instance.list_user_companies
    first_company_id = user_companies_response.data.companies[0].id

    # Retrieve the list of the Suppliers
    suppliers_api_instance = FattureInCloud_Ruby_Sdk::SuppliersApi.new
    company_suppliers = suppliers_api_instance.list_suppliers(first_company_id)
    response.body = company_suppliers.to_s
 
  end

  def retrieve_token_from_file()
    obj = JSON.parse(File.read("./token.json"))
    return obj["access_token"].to_s
  end

end