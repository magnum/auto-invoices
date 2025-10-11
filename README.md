# Auto Invoices

An automated invoice processing system that analyzes credit card statements and receipts using AI, matches transactions with suppliers, and prepares them for import into Fatture in Cloud (Italian invoicing platform).

## Overview

This Ruby script automates the tedious process of matching credit card transactions with supplier invoices. It uses OpenAI's GPT-4o model to extract structured data from PDF documents and employs fuzzy matching algorithms to automatically associate transactions with existing suppliers in your accounting system.

## Features

- **PDF Analysis**: Extracts transaction data from credit card statements (PDFs) using OpenAI GPT-4o
- **Receipt Processing**: Analyzes receipt PDFs to extract payment details (date, amount, supplier, invoice number)
- **Supplier Integration**: Fetches and caches supplier data from Fatture in Cloud API
- **Fuzzy Matching**: Automatically matches transaction descriptions with supplier names using intelligent fuzzy matching
- **Duplicate Detection**: Identifies similar supplier names to help clean up your supplier database
- **Interactive Selection**: User-friendly terminal interface to review and select transactions for processing
- **Data Caching**: Saves extracted data to JSON files to avoid re-processing and save API costs

## Prerequisites

- Ruby (version 2.7 or higher recommended)
- OpenAI API key with access to GPT-4o model
- Fatture in Cloud account with API access
- Bundler gem installed

## Installation

1. Clone this repository:
```bash
git clone <repository-url>
cd auto-invoices
```

2. Install dependencies:
```bash
bundle install
```

3. Create a `.env` file in the project root with your API credentials:
```env
OPENAI_API_KEY=your_openai_api_key_here
FATTUREINCLOUD_COMPANY_ID=your_company_id_here
FATTUREINCLOUD_ACCESS_TOKEN=your_access_token_here
```

## Configuration

The script uses the following environment variables:

- `OPENAI_API_KEY`: Your OpenAI API key for GPT-4o access
- `FATTUREINCLOUD_COMPANY_ID`: Your company ID from Fatture in Cloud
- `FATTUREINCLOUD_ACCESS_TOKEN`: Your API access token from Fatture in Cloud

## Usage

### Basic Usage

Run the script with paths to your credit card statement and receipts folder:

```bash
ruby auto-invoices.rb path/to/credit_card_statement.pdf path/to/receipts/folder
```

### Example

```bash
ruby auto-invoices.rb data/testd.pdf data/test/
```

### What Happens

1. **Extract Payments**: The script analyzes the credit card statement PDF and extracts all transactions
2. **Fetch Suppliers**: Retrieves all suppliers from your Fatture in Cloud account
3. **Process Receipts**: Analyzes receipt PDFs in the specified folder
4. **Match Transactions**: Uses fuzzy matching to associate transactions with suppliers
5. **Interactive Selection**: Displays a list where you can select which transactions to process
   - Use ↑/↓ arrow keys to navigate
   - Press SPACE to select/deselect items
   - Press ENTER to confirm your selection

### Data Caching

The script creates three JSON cache files:
- `auto-invoices-payments.json`: Extracted credit card transactions
- `auto-invoices-suppliers.json`: Cached supplier data from Fatture in Cloud
- `auto-invoices-receipts.json`: Extracted receipt data

If these files exist, the script will use the cached data instead of re-processing, saving time and API costs. Delete these files to force a fresh extraction.

## File Structure

```
auto-invoices/
├── auto-invoices.rb              # Main script
├── Gemfile                        # Ruby dependencies
├── .env                           # API credentials (create this)
├── data/                          # Test data directory
│   └── test/
│       ├── credit_card_statement.pdf
│       └── receipt1.pdf
├── auto-invoices-payments.json   # Generated: cached payments
├── auto-invoices-suppliers.json  # Generated: cached suppliers
└── auto-invoices-receipts.json   # Generated: cached receipts
```

## How It Works

### 1. Credit Card Statement Analysis
The script sends your credit card statement PDF to OpenAI GPT-4o with a prompt in Italian asking it to extract:
- Transaction date (DD/MM/YY format)
- Description
- Amount in euros
- Commissions (if any)
- Amount without commissions

### 2. Receipt Processing
Each receipt PDF is analyzed to extract:
- Payment date
- Receipt/invoice number
- Description
- Total amount
- Supplier name
- Currency

### 3. Supplier Matching
- Fetches all suppliers from Fatture in Cloud API (with pagination support)
- Uses fuzzy matching algorithm to match transaction descriptions with supplier names
- Threshold set to 0.3 for broad matching (can be adjusted)

### 4. Duplicate Detection (Optional)
The script includes a `report_similar_suppliers` function (currently commented out) that can identify potential duplicate suppliers in your database using fuzzy matching with a 0.8 threshold.

## API Integration

### OpenAI GPT-4o
- Model: `gpt-4o`
- Max tokens: 4096
- Response format: JSON object
- Input: Base64-encoded PDF content

### Fatture in Cloud API v2
- Endpoints used:
  - `GET /c/{company_id}/entities/suppliers` - Fetch suppliers
  - `GET /c/{company_id}/issued_documents` - Get last document number
- Pagination: Automatic handling of multiple pages
- Authentication: Bearer token

## Dependencies

- **dotenv**: Environment variable management
- **pry**: Debugging console (development)
- **openai**: OpenAI API client
- **httparty**: HTTP requests for Fatture in Cloud API
- **fuzzy_match**: Fuzzy string matching algorithm
- **tty-prompt**: Interactive terminal prompts

## Limitations & Notes

- Currently, the script processes transactions but stops before creating actual invoices (see line 174: `return` statement)
- The script is designed for Italian accounting workflows (Fatture in Cloud, Italian prompts)
- AI extraction accuracy depends on PDF quality and format
- API costs apply for OpenAI GPT-4o usage (approximately $0.01-0.03 per PDF page)
- Large credit card statements may require multiple API calls

## Future Enhancements

Potential improvements could include:
- Automatic invoice creation in Fatture in Cloud
- Support for multiple credit card statements
- Receipt-to-transaction matching
- Export to other accounting platforms
- Command-line options for threshold tuning
- Multi-language support

## Troubleshooting

**Issue**: API rate limits or errors
- Solution: Check your API keys and account limits

**Issue**: Poor matching results
- Solution: Adjust the fuzzy matching threshold (line 181)

**Issue**: Missing transactions
- Solution: Delete cache files and re-run to force fresh extraction

**Issue**: PDF not recognized
- Solution: Ensure PDFs are not encrypted or password-protected

## License

[MIT License](https://opensource.org/licenses/MIT)

## Author

Antonio Molinari - antoniomolinari@me.com

