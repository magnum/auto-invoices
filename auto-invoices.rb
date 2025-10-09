require 'dotenv'
Dotenv.load()
require 'pry'
require 'openai'
require 'base64'
require 'httparty'
require 'fuzzy_match'
require 'tty-prompt'

number_suffix = "auto"
cc_statement_path = ARGV[0]
receipts_path = ARGV[1]
@payments_json_filename = "auto-invoices-payments.json"
@payments = nil
@suppliers_json_filename = "auto-invoices-suppliers.json"
@suppliers = nil
@receipts_json_filename = "auto-invoices-receipts.json"
@receipts = nil


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
    File.write(@payments_json_filename, JSON.pretty_generate(data))
    data
end


def get_receipt_data(file_path) 
    data = []
    pdf_content = File.read(file_path)
    client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
    prompt = "
        Analizza ricevuta per pagamento PDF ed estrai i dati essenziali in formato JSON con: date (data del pagamento), receipt_number (numero della ricevuta o invoice number), description (descrizione), amount_total (importo totale), supplier_name (nome del fornitore).
        In amount_total indica solo il numero, non la valuta. 
        Metti la valuta in attributo currency.
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


def get_suppliers
    data = []
    url = "https://api-v2.fattureincloud.it/c/#{ENV["FATTUREINCLOUD_COMPANY_ID"]}/entities/suppliers?per_page=1000"
    next_page_url = nil
    loop do
        response = HTTParty.get(
            url,
            headers: {
                "Authorization" => "Bearer #{ENV["FATTUREINCLOUD_ACCESS_TOKEN"]}"
            }
        )
        response.dig("data").each do |supplier|
            data << supplier
        end
        url = response.dig("next_page_url")
        break unless url
    end
    #data = data.filter{|s| s["address_city"][0] rescue false}
    File.write(@suppliers_json_filename, JSON.pretty_generate(data))
    data
end


def get_document_last_number
    response = HTTParty.get(
        "https://api-v2.fattureincloud.it/c/#{ENV["FATTUREINCLOUD_COMPANY_ID"]}/issued_documents?type=self_supplier_invoice&fieldset=detailed&sort=-created_at",
        headers: {
            "Authorization" => "Bearer #{ENV["FATTUREINCLOUD_ACCESS_TOKEN"]}"
        }
    )
    number_last = response.dig("data", 0, "number")&.to_i
    number_last
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


def get_receipts(receipts_path)
    data = []
    files = Dir.glob(File.join(receipts_path, "*.*"))
    puts "Found #{files.length} receipts"
    files.each do |file|
        puts "Processing #{File.basename(file)}"
        data << get_receipt_data(file)
    end
    File.write(@receipts_json_filename, JSON.pretty_generate(data))
    data
end


#payments
@payments = File.exist?(@payments_json_filename) ? JSON.parse(File.read(@payments_json_filename)) : get_payments(cc_statement_path)
puts "Found #{@payments["transactions"].length} payments from credit card statement .pdf file"
#suppliers
@suppliers = File.exist?(@suppliers_json_filename) ? JSON.parse(File.read(@suppliers_json_filename)) : get_suppliers
puts "Read #{@suppliers.length} suppliers from Fatture in Cloud"
#report_similar_suppliers
# last document number
number_last = get_document_last_number
number_next = number_last + 1
puts "Last document number: #{number_last}#{number_suffix}, next number: #{number_next}#{number_suffix}"
#receipts
@receipts = File.exist?(@receipts_json_filename) ? JSON.parse(File.read(@receipts_json_filename)) : get_receipts(receipts_path)
puts "Found #{@receipts.length} receipts"
return


puts "mapping payments to suppliers"
@transactions = @payments["transactions"].map do |transaction|
    # fuzzy match supplier name
    fuzzy = FuzzyMatch.new(@suppliers, read: 'name')
    similar = fuzzy.find_all(transaction["description"], threshold: 0.3)
    if similar.length > 0
        transaction["supplier"] = similar.first
    end
    transaction
end


# Interactive selection
prompt = TTY::Prompt.new
choices = @transactions.map.with_index do |transaction, index|
  supplier_name = transaction["supplier"] ? transaction["supplier"]["name"] : "(no match)"
  label = "#{transaction["description"]} → #{supplier_name}"
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
  selected_transactions = selected_indices.map { |idx| @transactions[idx] }
  selected_transactions.each do |transaction|
    supplier_name = transaction["supplier"] ? transaction["supplier"]["name"] : "(no match)"
    supplier_id = transaction["supplier"] ? transaction["supplier"]["id"] : nil
    puts "\n#{transaction["description"]}"
    puts "  → Supplier: #{supplier_name}"
    puts "  → Supplier ID: #{supplier_id}" if supplier_id
    puts "  → Amount: €#{transaction["amount_euro"]}"
    puts "  → Date: #{transaction["date"]}"
  end

else
  puts "\nNo transactions selected."
end

