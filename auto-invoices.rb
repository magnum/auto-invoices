require 'dotenv'
Dotenv.load()
require 'pry'
require 'fattureincloud_ruby_sdk'
require 'openai'
require 'base64'
require 'httparty'
require 'fuzzy_match'
require 'tty-prompt'
require 'table_print'

@number_suffix = "auto"
cc_statement_path = ARGV[0]
receipts_path = ARGV[1]
@payments_json_filename = "auto-invoices-payments.json"
@payments = nil
@suppliers_json_filename = "auto-invoices-suppliers.json"
@suppliers = nil
@receipts_json_filename = "auto-invoices-receipts.json"
@receipts = nil


FattureInCloud_Ruby_Sdk.configure do |config|
    @access_token = JSON.parse(File.read("./token.json"))["access_token"] rescue nil
    unless @access_token
        puts "access_token not found, run ruby index.rb and visit the http://localhost:3000/oauth to set it" 
        return
    end
    config.access_token = @access_token
end
@api_instance = FattureInCloud_Ruby_Sdk::IssuedDocumentsApi.new


def json_read(code)
    filename = "auto-invoices-#{code}.json"
    return nil unless File.exist?(filename)
    JSON.parse(File.read(filename))
end


def json_write(code, data)
    File.write("auto-invoices-#{code}.json", JSON.pretty_generate(data))
end


def get_suppliers
    data = []
    url = "https://api-v2.fattureincloud.it/c/#{ENV["FATTUREINCLOUD_COMPANY_ID"]}/entities/suppliers?per_page=1000&fieldset=detailed"
    next_page_url = nil
    loop do
        response = HTTParty.get(
            url,
            headers: {
                "Authorization" => "Bearer #{@access_token}"
            }
        )
        response.dig("data").each do |supplier|
            data << supplier
        end
        url = response.dig("next_page_url")
        break unless url
    end
    #data = data.filter{|s| s["address_city"][0] rescue false}
    json_write("suppliers", data)
    data
end


def get_document_last_number
    response = HTTParty.get(
        "https://api-v2.fattureincloud.it/c/#{ENV["FATTUREINCLOUD_COMPANY_ID"]}/issued_documents?type=self_supplier_invoice&fieldset=detailed&sort=-created_at",
        headers: {
            "Authorization" => "Bearer #{@access_token}"
        }
    )
    @number_last = response.dig("data", 0, "number")&.to_i
    @number_last
end


def get_payments(cc_statement_path)
    data = []
    pdf_content = File.read(cc_statement_path)
    client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
    prompt = "Analizza questo estratto conto carta di credito PDF ed estrai TUTTE le transazioni presenti. Per ogni transazione crea un oggetto JSON con: date (formato gg/mm/aa), description (descrizione completa), amount_euro (importo in euro), commissions (importo commissioni se presenti, altrimenti 0), amount_without_commission (importo - commissioni)."
    content = [
    { type: "text", text: prompt },
    {
        type: "file",
        file: {
        filename: File.basename(cc_statement_path),
        file_data: "data:application/pdf;base64,#{Base64.strict_encode64(pdf_content)}"
        }
    }
    ]

    response = client.chat(
    parameters: {
        model: "gpt-4o",
        messages: [{
        role: "user",
        content: content
        }],
        max_tokens: 4096,
        response_format: { type: "json_object" }
    }
    )

    content = response.dig("choices", 0, "message", "content")
    content =~ /\A```json\s*(.*?)\s*```\s*\z/m  ? json_str = $1 : json_str = content
    data = JSON.parse(json_str)
    json_write("payments", data)
    data
end


def get_receipt_data(file_path) 
    data = []
    pdf_content = File.read(file_path)
    client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
    suppliers_for_match = @suppliers.map{|s| {id: s["id"], name: s["name"]}}
    prompt = "
        Analizza ricevuta per pagamento PDF ed estrai i dati essenziali in formato JSON con: date (data del pagamento), receipt_number (numero della ricevuta o invoice number), description (descrizione), amount_total (importo totale), supplier_name (nome del fornitore).
        In amount_total indica solo il numero, non la valuta. 
        La data deve essere in formato yyyy-mm-dd.
        Metti la valuta in attributo currency.
        Aggiungi attributo matched_supplier_id e matched_supplier_name.
        Ti aggiungo i fornitori per il match come json: #{suppliers_for_match.to_json}.
        Prova a impostare matched_supplier_id e matched_supplier_name in base al campo description o supplier_name, non usare una ricerca esatta, ma una ricerca fuzzy.
        Se non trovi un fornitore, lascia matched_supplier_id e matched_supplier_name vuoti.
    "
    content = [
    { type: "text", text: prompt },
    {
        type: "file",
        file: {
        filename: File.basename(file_path),
        file_data: "data:application/pdf;base64,#{Base64.strict_encode64(pdf_content)}"
        }
    }
    ]
    response = client.chat(
    parameters: {
        model: "gpt-4o",
        messages: [{
        role: "user",
        content: content
        }],
        max_tokens: 4096,
        response_format: { type: "json_object" }
    }
    )
    content = response.dig("choices", 0, "message", "content")
    content =~ /\A```json\s*(.*?)\s*```\s*\z/m  ? json_str = $1 : json_str = content
    data = JSON.parse(json_str)
    data
end


def get_receipts(receipts_path)
    data = []
    files = Dir.glob(File.join(receipts_path, "*.*"))
    puts "Found #{files.length} receipts"
    files.each do |file|
        puts "Processing #{File.basename(file)}"
        data << get_receipt_data(file)
    end
    json_write("receipts", data)
    data
end


def report_similar_suppliers
    data = JSON.parse(File.read(@suppliers_json_filename))
    dups = []
    data.each do |supplier|
        name = supplier['name']
        data_without_this = data.filter{|s| s['id'] != supplier['id']}
        fuzzy = FuzzyMatch.new(data_without_this, read: 'name')
        similar = fuzzy.find_all(name, threshold: 0.8)
        if similar.length > 1 && !dups.include?(supplier['id'])
            dups += similar.map{|s| s['id']}
            puts "#{supplier['id']} #{name} has similar names:"
            puts similar.map{|s| "- #{s['id']} #{s['name']} - #{s['address_city']}"}.join("\n")
            puts "--------------------------------"
        end
    end
end


def create_document2(receipt)
    puts "Creating invoice #{@number_next}#{@number_suffix} for #{receipt["matched_supplier_name"]} #{receipt["amount_total"]} €"
    @api_instance = FattureInCloud_Ruby_Sdk::IssuedDocumentsApi.new(FattureInCloud_Ruby_Sdk::ApiClient.new(@access_token))
    invoice = FattureInCloud_Ruby_Sdk::IssuedDocument.new(
        type: FattureInCloud_Ruby_Sdk::IssuedDocumentType::INVOICE,
        entity: receipt["supplier"],
        date: Date.parse(receipt["date"]),
        number: @number_next,
        numeration: @number_suffix,
        #subject: "servizi, #{receipt["description"]}",
        #visible_subject: "visible subject",
        # Retrieve the currencies: https://github.com/fattureincloud/fattureincloud-ruby-sdk/blob/master/docs/InfoApi.md#list_currencies
        currency: FattureInCloud_Ruby_Sdk::Currency.new( id: "EUR"),
        # Retrieve the languages: https://github.com/fattureincloud/fattureincloud-ruby-sdk/blob/master/docs/InfoApi.md#list_languages
        #language: FattureInCloud_Ruby_Sdk::Language.new(code: "it",name: "italiano"),
        items_list: Array(
            FattureInCloud_Ruby_Sdk::IssuedDocumentItemsListItem.new(
                name: "servizi, #{receipt["description"]}",
                net_price: receipt["amount_total"],
                qty: 1,
                # vat: FattureInCloud_Ruby_Sdk::VatType.new(
                #     id: 0
                # )
            )
        ),
        payments_list: Array(
            FattureInCloud_Ruby_Sdk::IssuedDocumentPaymentsListItem.new(
                amount: 122,
                due_date: Date.parse(receipt["date"]),
                paid_date: Date.parse(receipt["date"]),
                #https://github.com/fattureincloud/fattureincloud-ruby-sdk/blob/a8f115b44e267d3c225ae893968e3b70d89d4f9f/lib/fattureincloud_ruby_sdk/models/issued_document_status.rb#L17
                status: FattureInCloud_Ruby_Sdk::IssuedDocumentStatus::REVERSED,
            )
        ),
        ei_raw: {
            FatturaElettronicaBody: {
                DatiGenerali: {
                    DatiFattureCollegate: [
                        {
                            IdDocumento: receipt["receipt_number"],
                            DataDocumento: Date.parse(receipt["date"]).strftime("%Y-%m-%d"),
                        }
                    ]
                }
            }
        }
    )
    # Here we put our invoice in the request object
    opts = {
        create_issued_document_request: FattureInCloud_Ruby_Sdk::CreateIssuedDocumentRequest.new(data: invoice)
    }
    # Now we are all set for the final call
    # Create the invoice: https://github.com/fattureincloud/fattureincloud-ruby-sdk/blob/master/docs/IssuedDocumentsApi.md#create_issued_document
    begin
        result = @api_instance.create_issued_document(ENV["FATTUREINCLOUD_COMPANY_ID"], opts)
        p result
    rescue FattureInCloud_Ruby_Sdk::ApiError => e
        puts "Error when calling IssuedDocumentsApi->create_issued_document: #{e}"
    end
end


def create_document(receipt)
    data = {
        data: {
            type: "self_supplier_invoice",
            numeration: "auto",
            #subject: "test",
            entity: receipt["supplier"].merge({
                e_invoice: true,
                ei_code: "M5UXCR1",
                entity_type: "supplier",
                type: "company",
            }),
            date: receipt["date"],
            number: @number_next,
            use_gross_prices: false,
            items_list: [
                {
                    name: "servizi",
                    net_price: receipt["amount_total"],
                    apply_withholding_taxes: false,
                    qty: 1,
                    description: "servizi, #{receipt["description"]}"
                }
            ],
            payments_list: [
                {
                    amount: receipt["amount_total"]*1.22,
                    "status": "reversed",
                    "due_date": receipt["date"],
                }
            ],
            e_invoice: true,
            ei_data: {
                #https://www.fatturapa.gov.it/export/documenti/fatturapa/v1.3/Rappresentazione-tabellare-fattura-ordinaria.pdf
                payment_method: "MP08",
                document_type: "TD17"
            },
            ei_raw: {
                "FatturaElettronicaBody": {
                    "DatiGenerali": {
                        "DatiGeneraliDocumento": {
                            "TipoDocumento": "TD17"
                        },
                        "DatiFattureCollegate": [
                            {
                                "Data": Date.parse(receipt["date"]).strftime("%Y-%m-%d"),
                                "IdDocumento": receipt["receipt_number"]
                            }
                        ]
                    }
                },
                "FatturaElettronicaHeader": {
                    "CedentePrestatore": {
                        "DatiAnagrafici": {
                            "RegimeFiscale": "RF01"
                        }
                    }
                }
            }
        },
    }
    response = HTTParty.post(
        "https://api-v2.fattureincloud.it/c/#{ENV["FATTUREINCLOUD_COMPANY_ID"]}/issued_documents",
        headers: {
            "Authorization" => "Bearer #{@access_token}",
            "Content-Type" => "application/json",
        },
        body: data.to_json
    )
    #binding.pry
end

#payments
@payments = json_read("payments") || get_payments(cc_statement_path)
puts "Found #{@payments["transactions"].length} payments from credit card statement .pdf file"
#suppliers
@suppliers = json_read("suppliers") || get_suppliers
puts "Read #{@suppliers.length} suppliers from Fatture in Cloud"
#report_similar_suppliers
# last document number
@number_last = get_document_last_number
@number_next = @number_last + 1
puts "Last document number: #{@number_last}#{@number_suffix}, next number: #{@number_next}#{@number_suffix}"
#receipts
@receipts = json_read("receipts") || get_receipts(receipts_path)
puts "Found #{@receipts.length} receipts"
@receipts =@receipts.map do |receipt|
   next if receipt["matched_supplier_name"].length == 0
   receipt["supplier"] = @suppliers.find{|s| s["id"].to_s == receipt["matched_supplier_id"].to_s}
   receipt
end
json_write("receipts", @receipts)



# Interactive selection
prompt = TTY::Prompt.new
choices = @receipts.map.with_index do |receipt, index|
  label = "#{receipt["description"]} #{receipt["amount_total"]} → #{receipt["matched_supplier_name"].length > 0 ? receipt["matched_supplier_name"] : "(no match)"}"
  { name: label, value: index }
end

puts "Use ↑/↓ arrows to navigate, SPACE to select/deselect, ENTER to confirm\n\n"
selected_indices = prompt.multi_select(
  "Select transactions to include:",
  choices,
  per_page: 30,
  echo: false
)

if selected_indices.any?
  selected_receipts = selected_indices.map { |idx| @receipts[idx] }
  selected_receipts.each do |receipt|
    puts "Creating invoice #{@number_next}#{@number_suffix} for #{receipt["matched_supplier_name"]} #{receipt["amount_total"]} €"
    create_document(receipt)
    @number_next += 1
  end

else
  puts "\nNo transactions selected."
end

