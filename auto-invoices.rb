require 'dotenv'
Dotenv.load()
require 'fileutils'
require 'pry'
require 'openai'
require 'base64'
require 'httparty'
require 'tty-prompt'
require 'fuzzy_match'
require 'set'

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

begin
    @config[:date] = Date.parse(@config[:date].to_s).strftime("%Y-%m-%d")
rescue ArgumentError, Date::Error
    abort "Data non valida: #{ARGV[0].inspect}. Usa una data esistente, per esempio 2026-09-30 o 2026-10-31."
end

@payments = nil
@suppliers = nil
@receipts = nil
@errors = []

# Prova OCR: gpt-5.6-sol (sopra gpt-4o e gpt-5.4-mini, sotto i flagship tipo gpt-6-astra).
# Override: OPENAI_VISION_MODEL=gpt-4o oppure OPENAI_VISION_MODEL=gpt-6-astra
DEFAULT_OPENAI_VISION_MODEL = "gpt-5.6-sol"


def openai_client
    @openai_client ||= OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
end


def openai_vision_model
    ENV.fetch("OPENAI_VISION_MODEL", DEFAULT_OPENAI_VISION_MODEL)
end


def openai_reasoning_model?(model = openai_vision_model)
    model.match?(/\A(gpt-[56]|o\d)/)
end


def openai_pdf_chat_parameters(content)
    params = {
        model: openai_vision_model,
        messages: [{ role: "user", content: content }],
        response_format: { type: "json_object" }
    }
    if openai_reasoning_model?
        params[:max_completion_tokens] = 8192
        params[:reasoning_effort] = openai_vision_model.match?(/sol|astra/) ? "low" : "none"
    else
        params[:max_tokens] = 4096
    end
    params
end


def parse_openai_json_content(content)
    content =~ /\A```json\s*(.*?)\s*```\s*\z/m ? json_str = $1 : json_str = content
    JSON.parse(json_str)
end


def openai_pdf_json_chat(content)
    response = openai_client.chat(parameters: openai_pdf_chat_parameters(content))
    message_content = response.dig("choices", 0, "message", "content")
    raise "OpenAI: risposta vuota (#{openai_vision_model})" if message_content.nil? || message_content.strip.empty?

    parse_openai_json_content(message_content)
end


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


def receipt_payment_hash(receipt)
    payment = receipt["payment"]
    return payment if payment.is_a?(Hash)
    return nil if payment.nil? || payment == ""

    if payment.is_a?(String)
        begin
            parsed = JSON.parse(payment)
            return parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
            nil
        end
    end

    nil
end


def payment_transactions
    (@payments || {}).fetch("transactions", [])
end


def receipt_match_text(receipt)
    [
        receipt["description"],
        receipt["supplier_name"],
        receipt["matched_supplier_name"],
        receipt.dig("supplier", "name"),
        receipt["receipt_number"],
        File.basename(receipt["file_path"].to_s, ".pdf"),
    ].compact.join(" ")
end


def parse_transaction_date(date_str)
    return nil if date_str.nil? || date_str.to_s.strip.empty?

    if date_str.to_s.include?("/")
        day, month, year = date_str.split("/").map(&:to_i)
        year += 2000 if year < 100
        return Date.new(year, month, day)
    end

    Date.parse(date_str.to_s)
rescue ArgumentError, Date::Error
    nil
end


def receipt_date(receipt)
    Date.parse(receipt["date"].to_s)
rescue ArgumentError, Date::Error
    nil
end


PAYMENT_TEXT_STOPWORDS = %w[
    invoice fattura receipt payment pagamento per for the and with from
    subscription plan monthly annual acquisto servizi service numero
].freeze


def payment_text_tokens(text)
    text.to_s.downcase.scan(/[a-z0-9]{4,}/) - PAYMENT_TEXT_STOPWORDS
end


def receipt_currency_eur?(receipt)
    currency = receipt["currency"].to_s.upcase
    currency.empty? || currency == "EUR"
end


def payment_amount_ratio(transaction, receipt)
    receipt_amount = receipt["amount_total"].to_f.abs
    txn_amount = transaction["amount_without_commission"].to_f.abs
    return nil if receipt_amount <= 0 || txn_amount <= 0

    txn_amount / receipt_amount
end


def payment_amount_close?(transaction, receipt)
    ratio = payment_amount_ratio(transaction, receipt)
    return false unless ratio

    if receipt_currency_eur?(receipt)
        (ratio - 1).abs <= 0.03
    else
        ratio.between?(0.78, 1.02)
    end
end


def payment_amount_acceptable?(transaction, receipt)
    ratio = payment_amount_ratio(transaction, receipt)
    return false unless ratio

    if receipt_currency_eur?(receipt)
        (ratio - 1).abs <= 0.12
    else
        ratio.between?(0.70, 1.08)
    end
end


def payment_date_days(transaction, receipt)
    rd = receipt_date(receipt)
    td = parse_transaction_date(transaction["date"])
    return nil unless rd && td

    (rd - td).abs
end


def transaction_fuzzy_score(receipt_text, transaction)
    matcher = FuzzyMatch.new([transaction], read: "description")
    result = matcher.find_with_score(receipt_text)
    return 0 unless result

    result[1].to_f
end


def payment_text_score(receipt, transaction)
    receipt_text = receipt_match_text(receipt)
    fuzzy_score = transaction_fuzzy_score(receipt_text, transaction)
    receipt_tokens = payment_text_tokens(receipt_text)
    transaction_tokens = payment_text_tokens(transaction["description"])
    overlap = if receipt_tokens.empty? || transaction_tokens.empty?
        0.0
    else
        shared = receipt_tokens.count do |token|
            transaction_tokens.any? { |other| other.include?(token) || token.include?(other) }
        end
        shared.to_f / [receipt_tokens.length, 3].min
    end

    [fuzzy_score, overlap].max
end


def payment_match_score(transaction, receipt, text_score)
    return -Float::INFINITY unless payment_amount_acceptable?(transaction, receipt)
    return -Float::INFINITY if text_score < 0.18 && !payment_amount_close?(transaction, receipt)

    days = payment_date_days(transaction, receipt)
    if days && days > 75 && !payment_amount_close?(transaction, receipt)
        return -Float::INFINITY
    end

    amount_bonus = payment_amount_close?(transaction, receipt) ? 40 : 0
    date_bonus = days && days <= 14 ? 8 : 0
    (text_score * 100) + amount_bonus + date_bonus
end


def payment_same_transaction?(left, right)
    return false unless left.is_a?(Hash) && right.is_a?(Hash)

    left["description"].to_s == right["description"].to_s &&
        left["date"].to_s == right["date"].to_s &&
        left["amount_without_commission"].to_f == right["amount_without_commission"].to_f
end


def find_payment_transaction_index(payment)
    payment_transactions.each_with_index do |transaction, index|
        return index if payment_same_transaction?(transaction, payment)
    end
    nil
end


def assign_unique_eur_amounts!(receipts, transactions, used_transactions, used_receipts, assignments)
    unmatched = receipts.each_index.reject { |index| used_receipts.include?(index) }
    unmatched.select { |index| receipt_currency_eur?(receipts[index]) }.group_by { |index|
        receipts[index]["amount_total"].to_f.round(2)
    }.each do |amount, receipt_indexes|
        next if amount <= 0

        transaction_indexes = transactions.each_index.select do |index|
            next false if used_transactions.include?(index)

            txn_amount = transactions[index]["amount_without_commission"].to_f.abs
            (txn_amount - amount).abs <= [0.05, amount * 0.01].max
        end
        next unless transaction_indexes.length == receipt_indexes.length

        receipt_indexes.zip(transaction_indexes).each do |receipt_index, transaction_index|
            used_transactions << transaction_index
            used_receipts << receipt_index
            assignments[receipt_index] = transactions[transaction_index]
        end
    end
end


def assign_payments_to_receipts!(receipts)
    transactions = payment_transactions
    return if transactions.empty?

    pairs = []
    receipts.each_with_index do |receipt, receipt_index|
        transactions.each_with_index do |transaction, transaction_index|
            text_score = payment_text_score(receipt, transaction)
            score = payment_match_score(transaction, receipt, text_score)
            next if score < 35

            pairs << [score, receipt_index, transaction_index, transaction]
        end
    end

    pairs.sort_by! { |score, _, _, _| -score }
    used_transactions = Set.new
    used_receipts = Set.new
    assignments = {}

    pairs.each do |_score, receipt_index, transaction_index, transaction|
        next if used_transactions.include?(transaction_index)
        next if used_receipts.include?(receipt_index)

        used_transactions << transaction_index
        used_receipts << receipt_index
        assignments[receipt_index] = transaction
    end

    assign_unique_eur_amounts!(receipts, transactions, used_transactions, used_receipts, assignments)

    receipts.each_with_index do |receipt, receipt_index|
        receipt["payment"] = assignments[receipt_index]
    end
end


def assign_suppliers!(receipts)
    return if @suppliers.nil? || @suppliers.empty?

    fuzzy = FuzzyMatch.new(@suppliers, read: "name")
    receipts.each do |receipt|
        existing = @suppliers.find { |supplier| supplier["id"].to_s == receipt["matched_supplier_id"].to_s }
        if existing
            receipt["supplier"] = existing
            next
        end

        query = receipt["supplier_name"].to_s.strip
        query = receipt["description"].to_s.strip if query.empty?
        hit = fuzzy.find_with_score(query) if query.length >= 3
        if hit && hit[1].to_f >= 0.42
            receipt["supplier"] = hit[0]
            receipt["matched_supplier_id"] = hit[0]["id"]
            receipt["matched_supplier_name"] = hit[0]["name"]
        else
            receipt["supplier"] = nil
        end
    end
end


def llm_assign_unmatched_payments!(receipts)
    unmatched = receipts.each_with_index.select { |receipt, _index| receipt_payment_hash(receipt).nil? }
    return if unmatched.empty?

    used = receipts.filter_map { |receipt| find_payment_transaction_index(receipt_payment_hash(receipt)) }.to_set
    free = payment_transactions.each_with_index.reject { |_transaction, index| used.include?(index) }
    return if free.empty?

    payload = {
        receipts: unmatched.map { |receipt, index|
            {
                index: index,
                description: receipt["description"],
                supplier_name: receipt["supplier_name"],
                amount_total: receipt["amount_total"],
                currency: receipt["currency"],
                date: receipt["date"]
            }
        },
        transactions: free.map { |transaction, index|
            {
                index: index,
                date: transaction["date"],
                description: transaction["description"],
                amount_euro: transaction["amount_without_commission"]
            }
        }
    }
    prompt = <<~PROMPT
        Abbina le ricevute alle transazioni della carta di credito.
        Una transazione può essere usata una sola volta.
        Per gli importi in USD la transazione è in euro: il cambio è circa 0.80-1.00 euro per dollaro.
        Se non sei sicuro, non abbinare quella ricevuta.
        Rispondi solo con JSON: {"matches":[{"receipt_index":0,"transaction_index":1}]}
        Dati: #{payload.to_json}
    PROMPT
    puts "Asking #{openai_vision_model} to match #{unmatched.length} receipts still without an amount"
    parsed = openai_pdf_json_chat([{ type: "text", text: prompt }])
    matches = parsed["matches"]
    return unless matches.is_a?(Array)

    claimed = used.dup
    matches.each do |match|
        receipt_index = Integer(match["receipt_index"])
        transaction_index = Integer(match["transaction_index"])
        next if claimed.include?(transaction_index)
        next unless receipts[receipt_index] && payment_transactions[transaction_index]
        next unless receipt_payment_hash(receipts[receipt_index]).nil?

        transaction = payment_transactions[transaction_index]
        next unless payment_amount_acceptable?(transaction, receipts[receipt_index])

        receipts[receipt_index]["payment"] = transaction
        claimed << transaction_index
    rescue ArgumentError, TypeError
        next
    end
rescue StandardError => error
    puts "Payment match fallback skipped: #{error.message}"
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
        #binding.pry
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
    @number_last = response.dig("data")
    .filter{|doc| doc["year"].to_i == Date.today.year}
    .map{|doc| doc["number"]}
    .sort.last&.to_i
    #binding.pry
    raise "get_document_last_number error: #{response.dig("error")} #{response.dig("error_description")}" if response.dig("error")
    @number_last
end


def get_payments
    pdf_content = File.read(@config[:cc_statement_path])
    prompt = 
    <<~PROMPT
    Analizza questo estratto conto carta di credito PDF ed estrai tutte le transazioni presenti. 
        Per ogni transazione crea un oggetto JSON con: 
        date (formato gg/mm/aa), 
        description (descrizione completa), 
        amount_euro (importo in euro), 
        commissions (importo commissioni se presenti, altrimenti 0), 
        amount_without_commission (importo - commissioni).
        
        il formato del json deve essere:
        {
            "transactions": [
                {
                "date": "01/01/26",
                "description": "Google Workspace Incode.Imilan",
                "amount_euro": 50.97,
                "commissions": 0,
                "amount_without_commission": 50.97
                },
                ...
            ]
        }
    PROMPT
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

    data = openai_pdf_json_chat(content)
    json_write("payments", data)
    #binding.pry
    data
end


def get_receipt_data(file_path) 
    pdf_content = File.read(file_path)
    prompt = "
        Analizza il file pdf della ricevuta di pagamentoed estrai i dati essenziali in formato JSON con i seguenti attributi: 
        date (data del pagamento), 
        receipt_number (numero della ricevuta o invoice number), 
        description (descrizione), 
        amount_total (importo totale), 
        supplier_name (nome del fornitore, come scritto sulla ricevuta).
        In amount_total indica solo il numero, non la valuta.
        La data deve essere in formato yyyy-mm-dd.
        Metti la valuta in attributo currency (EUR, USD, ...).
        Non inventare importi: usa il totale della ricevuta.
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
    openai_pdf_json_chat(content)
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
    net_price = receipt_amount_eur(receipt)
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
                                "IdDocumento": receipt["receipt_number"].to_s[0, 20]
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
assign_suppliers!(@receipts)
assign_payments_to_receipts!(@receipts)
llm_assign_unmatched_payments!(@receipts)
json_write("receipts", @receipts.compact)
matched = @receipts.count { |receipt| !receipt_payment_hash(receipt).nil? }
puts "Matched #{matched}/#{@receipts.length} receipts to credit card transactions"


class String
    def truncate(length)
        ellipsis = "... "
        return "#{self}#{" "*(length-self.length)}" if self.length < length - ellipsis.length
        self.length > (length-ellipsis.length) ? self[0..(length-ellipsis.length)] + ellipsis : self
    end
end


def receipt_without_transaction?(receipt)
    receipt_payment_hash(receipt).nil?
end


def receipt_needs_conversion?(receipt)
    receipt["currency"].to_s.upcase == "USD"
end


def receipt_markers(receipt)
    marks = []
    marks << "*" if receipt_without_transaction?(receipt)
    marks << "#" if receipt_needs_conversion?(receipt)
    marks.join
end


def load_usd_eur_rates(dates)
    parsed = dates.filter_map do |value|
        Date.parse(value.to_s)
    rescue ArgumentError, Date::Error
        nil
    end
    @usd_eur_rates = {}
    return if parsed.empty?

    from = parsed.min - 7
    to = parsed.max
    response = HTTParty.get("https://api.frankfurter.dev/v1/#{from}..#{to}?from=USD&to=EUR")
    series = response["rates"]
    raise "Cambio USD/EUR non disponibile (#{from}..#{to})" unless series.is_a?(Hash)

    @usd_eur_rates = series
end


def usd_to_eur_rate(date)
    day = Date.parse(date.to_s)
    8.times do
        rate = @usd_eur_rates.dig(day.strftime("%Y-%m-%d"), "EUR")
        return rate.to_f if rate

        day -= 1
    end
    raise "Cambio USD/EUR non disponibile per #{date}"
end


def receipt_amount_eur(receipt)
    amount = receipt["amount_total"].to_f
    if receipt_needs_conversion?(receipt)
        (amount * usd_to_eur_rate(receipt["date"])).round(2)
    elsif receipt_without_transaction?(receipt)
        amount
    else
        receipt_payment_hash(receipt)["amount_without_commission"].to_f
    end
end


def receipt_amount_label(receipt)
    labels = []
    labels << "no-transaction" if receipt_without_transaction?(receipt)
    labels << "converted" if receipt_needs_conversion?(receipt)
    amount = sprintf("%.2f", receipt_amount_eur(receipt))
    labels.empty? ? amount : "#{labels.join(" ")} #{amount}"
end


def amount_legend_lines
    [
        "* no-transaction: nessun movimento in estratto conto, importo preso dal documento",
        "# converted: importo in USD convertito in EUR alla data della ricevuta",
    ]
end


def print_amount_legend
    amount_legend_lines.each { |line| puts line }
end


def print_to_check(receipts)
    no_transaction = receipts.select { |receipt| receipt_without_transaction?(receipt) }
    converted = receipts.select { |receipt| receipt_needs_conversion?(receipt) }
    return if no_transaction.empty? && converted.empty?

    puts "\nto check"
    if no_transaction.any?
        puts "\nno-transaction"
        no_transaction.each { |receipt| puts receipt_info(receipt) }
    end
    if converted.any?
        puts "\nconverted"
        converted.each { |receipt| puts receipt_info(receipt) }
    end
    puts
    print_amount_legend
end


def receipt_info(receipt)
    line = [
        "#{receipt["description"]&.truncate(30)}",
        "#{sprintf("%.2f", receipt["amount_total"].to_f)} #{receipt["currency"]}",
        "→",
        receipt_amount_label(receipt),
        "→",
        (receipt.dig("supplier", "name") || "NO-SUPPLIER"),
    ].join(" ")
    mark = receipt_markers(receipt)
    mark.empty? ? line : "#{line} #{mark}"
end

# Interactive selection
load_usd_eur_rates(@receipts.select { |receipt| receipt_needs_conversion?(receipt) }.map { |receipt| receipt["date"] })
prompt = TTY::Prompt.new
choices = @receipts.map.with_index do |receipt, index|
    { name: receipt_info(receipt), value: index }
end
choices.concat(amount_legend_lines.map { |line| { name: line, value: nil, disabled: "\u200b" } })
puts "Use ↑/↓ arrows to navigate, SPACE to select/deselect, ENTER to confirm\n\n"
selected_indices = prompt.multi_select(
  "Select transactions to include:",
  choices,
  per_page: 100,
  echo: false,
  symbols: { cross: " " }
)
selected_indices = selected_indices.compact
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
print_to_check(@receipts)

