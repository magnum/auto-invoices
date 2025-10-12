require 'dotenv'
Dotenv.load()
require 'fileutils'
require 'pry'
require 'openai'
require 'base64'
require 'httparty'
require 'tty-prompt'

# Gracefully handle Ctrl+C
Signal.trap("INT") do
  puts "\n\nExiting gracefully..."
  exit 0
end

@fic_access_token = JSON.parse(File.read("./token.json"))["access_token"] rescue nil

@config = {
    date: Date.today.strftime("%Y-%m-%d"),
    number_suffix: "auto",
    description: "servizi",
    subdir: nil
}

@config[:date] = ARGV[0]
@config[:subdir] = ARGV[1]
@config[:cc_statement_path] = ARGV[2]
@config[:receipts_path] = ARGV[3]

@payments = nil
@suppliers = nil
@receipts = nil
@errors = []


def json_file_path(code)
    FileUtils.mkdir_p(File.join("data", @config[:subdir]))
    File.join("data", @config[:subdir], "#{code}.json")
end


def json_read(code)
    file_path = json_file_path(code)
    return nil unless File.exist?(file_path)
    JSON.parse(File.read(file_path))
end


def json_write(code, data)
    File.write(json_file_path(code), JSON.pretty_generate(data))
end


def get_suppliers
    data = []
    url = "https://api-v2.fattureincloud.it/c/#{ENV["FATTUREINCLOUD_COMPANY_ID"]}/entities/suppliers?per_page=1000&fieldset=detailed"
    next_page_url = nil
    loop do
        response = HTTParty.get(
            url,
            headers: {
                "Authorization" => "Bearer #{@fic_access_token}"
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
            "Authorization" => "Bearer #{@fic_access_token}"
        }
    )
    @number_last = response.dig("data", 0, "number")&.to_i
    @number_last
end


def get_payments
    data = []
    pdf_content = File.read(@config[:cc_statement_path])
    client = OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
    prompt = "Analizza questo estratto conto carta di credito PDF ed estrai tutte le transazioni presenti. 
        Per ogni transazione crea un oggetto JSON con: 
        date (formato gg/mm/aa), 
        description (descrizione completa), 
        amount_euro (importo in euro), 
        commissions (importo commissioni se presenti, altrimenti 0), 
        amount_without_commission (importo - commissioni)."
    content = [
    { type: "text", text: prompt },
    {
        type: "file",
        file: {
        filename: File.basename(@config[:cc_statement_path]),
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
        Analizza il file pdf della ricevuta di pagamentoed estrai i dati essenziali in formato JSON con i seguenti attributi: 
        date (data del pagamento), 
        receipt_number (numero della ricevuta o invoice number), 
        description (descrizione), 
        amount_total (importo totale), 
        supplier_name (nome del fornitore).
        In amount_total indica solo il numero, non la valuta. 
        La data deve essere in formato yyyy-mm-dd.
        Metti la valuta in attributo currency.
        Aggiungi attributo matched_supplier_id e matched_supplier_name inizialmente vuoti.
        
        Ti aggiungo lista fornitori come json: #{suppliers_for_match.to_json}.
        Trova il fornitore utilizzando l'attributo name degli elementi del json fornitori
        e confrontandolo con l'attributo supplier_name della ricevuta, 
        non usare una ricerca esatta, ma una ricerca fuzzy perchè a volte il nome del fornitore è scritto in modo diverso.
        Se trovi un fornitore valorizza gli attributi matched_supplier_id e matched_supplier_name con l'id e il name del fornitore.
        Se non trovi un fornitore, lascia matched_supplier_id e matched_supplier_name vuoti.
        
        Ti aggiungo anche lista pagamenti come json: #{@payments.to_json}.
        Trova il pagamento utilizzando l'attributo description degli elementi del json pagamenti  
        e confrontandolo con il campo description della ricevuta,
        non usare una ricerca esatta, ma una ricerca fuzzy perchè a volte il nome del fornitore è scritto in modo diverso.
        Se trovi un pagmamento valorizza l'attributo payment della ricevuta con l'oggetto payment dal json pagamenti.
        Se ci sono due pagamenti simili come descrizione, prendi quello con l'importo più vicino al totale della ricevuta.  
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


def get_receipts
    data = []
    files = Dir.glob(File.join(@config[:receipts_path], "*.pdf"))
    puts "Found #{files.length} receipts"
    files.each do |file_path|
        puts "Processing #{File.basename(file_path)}"
        data << (get_receipt_data(file_path) || {}).merge({file_path: file_path})
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


def create_document(receipt)
    net_price = (receipt.dig("payment", "amount_without_commission") || 0).to_f
    gross_price = net_price*1.22
    data = {
        data: {
            type: "self_supplier_invoice",
            numeration: "auto",
            #subject: "test",
            entity: (receipt["supplier"] || {}).merge({
                e_invoice: true,
                ei_code: "M5UXCR1",
                entity_type: "supplier",
                type: "company",
            }),
            date: Date.parse(@config[:date]).strftime("%Y-%m-%d"),
            number: @number_next,
            use_gross_prices: false,
            items_list: [
                {
                    name: @config[:description],
                    net_price: net_price,
                    apply_withholding_taxes: false,
                    qty: 1,
                    description: "#{receipt["description"]}"
                }
            ],
            payments_list: [
                {
                    amount: gross_price,
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
            "Authorization" => "Bearer #{@fic_access_token}",
            "Content-Type" => "application/json",
        },
        body: data.to_json
    )
    #binding.pry
    if response.dig("error")
        @errors << receipt_info(receipt)
    end
    puts "#{response.dig("error", "message")} #{response.dig("error", "validation_result")}" || response.dig("data", "id")
end

#payments
@payments = json_read("payments") || get_payments
puts "Found #{@payments["transactions"].length} payments from credit card statement '#{File.basename(@config[:cc_statement_path])}'"
#suppliers
@suppliers = json_read("suppliers") || get_suppliers
puts "Read #{@suppliers.length} suppliers from Fatture in Cloud"
#report_similar_suppliers
# last document number
@number_last = get_document_last_number
@number_next = @number_last + 1
puts "Last document number: #{@number_last}#{@config[:number_suffix]}, next number: #{@number_next}#{@config[:number_suffix]}"
#receipts
@receipts = json_read("receipts") || get_receipts
puts "Found #{@receipts.length} receipts"
@receipts = @receipts.map do |receipt|
    receipt["supplier"] = @suppliers.find{|s| s["id"].to_s == receipt["matched_supplier_id"].to_s}
    receipt
end
json_write("receipts", @receipts.compact)


class String
    def truncate(length)
        ellipsis = "... "
        return "#{self}#{" "*(length-self.length)}" if self.length < length - ellipsis.length
        self.length > (length-ellipsis.length) ? self[0..(length-ellipsis.length)] + ellipsis : self
    end
end


def receipt_info(receipt)
    [
        "#{receipt["description"].truncate(30)}",
        "#{sprintf("%.2f", receipt["amount_total"])} #{receipt["currency"]}",
        "→",
        (receipt.dig("payment", "amount_without_commission") || "NO-AMOUNT"),
        "→",
        (receipt.dig("supplier", "name") || "NO-SUPPLIER"),
    ].join(" ")
end

# Interactive selection
prompt = TTY::Prompt.new
choices = @receipts.map.with_index do |receipt, index|
    { name: receipt_info(receipt), value: index }
end
puts "Use ↑/↓ arrows to navigate, SPACE to select/deselect, ENTER to confirm\n\n"
selected_indices = prompt.multi_select(
  "Select transactions to include:",
  choices,
  per_page: 100,
  echo: false
)
if selected_indices.any?
  selected_receipts = selected_indices.map { |idx| @receipts[idx] }
  selected_receipts.each do |receipt|
    puts "Creating invoice #{@number_next}#{@config[:number_suffix]} #{receipt_info(receipt)}"
    create_document(receipt)
    @number_next += 1
  end
end
if @errors.any?
    puts "Errors:"
    @errors.each do |error|
        puts error
    end
end

