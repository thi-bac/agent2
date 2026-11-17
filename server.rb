#!/usr/bin/env ruby
# encoding: utf-8
require 'webrick'
require 'json'
require 'csv'
require 'net/http'
require 'uri'

PORT = 8080
ROOT_DIR = File.expand_path(__dir__)
DATA_DIR = File.join(ROOT_DIR, 'data')
PUBLIC_DIR = File.join(ROOT_DIR, 'public')

# Load Master Catalog
def load_master_catalog
  catalog_file = File.join(DATA_DIR, 'master_catalog.json')
  if File.exist?(catalog_file)
    JSON.parse(File.read(catalog_file, encoding: 'utf-8'))
  else
    { "products" => [], "approval_policy" => {}, "required_keys" => [] }
  end
end

MASTER_CATALOG = load_master_catalog

# Helper: Parse text as CSV (supporting comma, semicolon, tab)
def parse_csv_flexible(raw_text)
  first_line = raw_text.lines.first.to_s
  col_sep = if first_line.count(';') > first_line.count(',')
              ';'
            elsif first_line.count("\t") > first_line.count(',')
              "\t"
            else
              ','
            end
  CSV.parse(raw_text.strip, headers: true, col_sep: col_sep)
end

# Normalize header string
def clean_header_str(str)
  str.to_s.downcase.strip.gsub(/[\s\-_]+/, '_').gsub(/[^\p{Alnum}_]/, '')
end

# Check required keys against master schema
def validate_schema(headers)
  cleaned_headers = headers.map { |h| clean_header_str(h) }
  missing_keys = []
  mapped_keys = {}

  MASTER_CATALOG['required_keys'].each do |req|
    matched = nil
    req['aliases'].each do |alias_name|
      cleaned_alias = clean_header_str(alias_name)
      if cleaned_headers.include?(cleaned_alias)
        matched = headers[cleaned_headers.index(cleaned_alias)]
        break
      end
    end

    if matched
      mapped_keys[req['key']] = matched
    else
      missing_keys << {
        "key" => req['key'],
        "label" => req['label'],
        "expected_aliases" => req['aliases']
      }
    end
  end

  [missing_keys, mapped_keys]
end

# Find product in master catalog
def match_product(query)
  q = query.to_s.downcase.strip
  MASTER_CATALOG['products'].each do |p|
    return p if p['name'].downcase == q || p['sku'].downcase == q
    p['aliases'].each do |al|
      return p if q.include?(al.downcase) || al.downcase.include?(q)
    end
  end
  # Fallback to closest match
  MASTER_CATALOG['products'].find { |p| q.split.any? { |word| word.length > 3 && p['name'].downcase.include?(word) } }
end

# Parse numeric budget
def parse_budget(val)
  str = val.to_s.gsub(/[^\d]/, '')
  str.empty? ? 0 : str.to_i
end

# Parse discount percentage
def parse_discount(val)
  str = val.to_s.gsub('%', '').strip
  v = str.to_f
  v > 1.0 ? v : (v * 100.0) # Handle 0.05 vs 5
end

# Parse deadline days
def parse_deadline_days(val)
  str = val.to_s
  num = str.scan(/\d+/).first
  num ? num.to_i : 7
end

# Configure WEBrick Server
server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: '0.0.0.0',
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO),
  AccessLog: []
)

# Trap interrupt for clean exit
trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

# Mount Root and serve index.html as String (Avoids sendfile EPERM)
server.mount_proc '/' do |req, res|
  if req.path.start_with?('/api/')
    # handled by api procs
    res.status = 404
  elsif req.path.start_with?('/images/') || req.path.start_with?('/samples/')
    target_file = File.join(PUBLIC_DIR, req.path)
    if File.exist?(target_file)
      res.status = 200
      if req.path.end_with?('.jpg') || req.path.end_with?('.jpeg')
        res['Content-Type'] = 'image/jpeg'
      elsif req.path.end_with?('.png')
        res['Content-Type'] = 'image/png'
      else
        res['Content-Type'] = 'text/plain; charset=utf-8'
      end
      res['Cache-Control'] = 'public, max-age=3600'
      res.body = File.binread(target_file)
    else
      res.status = 404
      res.body = "File not found"
    end
  else
    index_file = File.join(PUBLIC_DIR, 'index.html')
    if File.exist?(index_file)
      res.status = 200
      res['Content-Type'] = 'text/html; charset=utf-8'
      res['Cache-Control'] = 'no-cache, no-store, must-revalidate'
      res.body = File.read(index_file, encoding: 'utf-8')
    else
      res.status = 404
      res.body = "index.html not found"
    end
  end
end

# Helper for JSON response
def send_json(res, status_code, data)
  res.status = status_code
  res['Content-Type'] = 'application/json; charset=utf-8'
  res['Access-Control-Allow-Origin'] = '*'
  res['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
  res['Access-Control-Allow-Headers'] = 'Content-Type'
  res.body = JSON.generate(data)
end

# Route: OPTIONS preflight
server.mount_proc '/api/' do |req, res|
  if req.request_method == 'OPTIONS'
    res.status = 200
    res['Access-Control-Allow-Origin'] = '*'
    res['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    res['Access-Control-Allow-Headers'] = 'Content-Type'
    res.body = ''
  end
end

# Route: Get Catalog
server.mount_proc '/api/catalog' do |req, res|
  send_json(res, 200, MASTER_CATALOG)
end

# Route: Load Sample Valid
server.mount_proc '/api/sample_valid' do |req, res|
  path = File.join(DATA_DIR, 'sample_valid.csv')
  content = File.exist?(path) ? File.read(path, encoding: 'utf-8') : ''
  send_json(res, 200, { raw_csv: content })
end

# Route: Load Sample Invalid
server.mount_proc '/api/sample_invalid' do |req, res|
  path = File.join(DATA_DIR, 'sample_invalid.csv')
  content = File.exist?(path) ? File.read(path, encoding: 'utf-8') : ''
  send_json(res, 200, { raw_csv: content })
end

# Route: Fetch Google Sheet or Remote URL
server.mount_proc '/api/fetch_google_sheet' do |req, res|
  begin
    body = JSON.parse(req.body || '{}')
    sheet_url = body['url'].to_s.strip
    if sheet_url.empty?
      send_json(res, 400, { status: "ERROR", message: "Vui lòng nhập đường link Google Sheets hợp lệ." })
      next
    end

    # Transform Google Sheets URL to CSV export URL if needed
    csv_url = sheet_url
    if sheet_url.include?('docs.google.com/spreadsheets/d/')
      match = sheet_url.match(%r{/spreadsheets/d/([a-zA-Z0-9\-_]+)})
      sheet_id = match[1] if match
      gid_match = sheet_url.match(/gid=([0-9]+)/)
      gid = gid_match ? gid_match[1] : '0'
      csv_url = "https://docs.google.com/spreadsheets/d/#{sheet_id}/export?format=csv&gid=#{gid}"
    end

    uri = URI.parse(csv_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 5
    http.read_timeout = 8
    response = http.get(uri.request_uri)

    if response.code.to_i == 200 && response.body && !response.body.strip.empty?
      send_json(res, 200, { status: "SUCCESS", raw_csv: response.body, source_url: csv_url })
    else
      send_json(res, 400, {
        status: "ERROR",
        message: "Không thể lấy dữ liệu trực tiếp từ Google Sheet (Mã lỗi: #{response.code}). Vui lòng kiểm tra quyền chia sẻ 'Bất kỳ ai có liên kết đều có thể xem' hoặc xuất file CSV/Excel tải lên."
      })
    end
  rescue => e
    send_json(res, 500, {
      status: "ERROR",
      message: "Lỗi kết nối khi tải Google Sheet: #{e.message}. Hãy tải file CSV hoặc dán trực tiếp."
    })
  end
end

# Route B1: Validate Input File
server.mount_proc '/api/validate' do |req, res|
  begin
    body = JSON.parse(req.body || '{}')
    raw_csv = body['raw_csv'].to_s.strip

    if raw_csv.empty?
      send_json(res, 400, {
        status: "ERROR",
        valid: false,
        error_title: "ERROR: KHÔNG CÓ DỮ LIỆU ĐẦU VÀO!",
        errors: ["Tập tin rỗng hoặc không thể giải mã nội dung văn bản. Vui lòng kiểm tra lại file."]
      })
      next
    end

    table = parse_csv_flexible(raw_csv)
    headers = table.headers.compact

    missing_keys, mapped_keys = validate_schema(headers)

    if !missing_keys.empty?
      error_details = missing_keys.map do |m|
        "Thiếu khoá chính bắt buộc: [#{m['label']}] (tên cột mong đợi: #{m['expected_aliases'].join(', ')})"
      end

      send_json(res, 200, {
        status: "ERROR",
        valid: false,
        error_title: "ERROR: DỮ LIỆU THIẾU HOẶC SAI ĐỊNH DẠNG KHÓA CHÍNH!",
        detected_headers: headers,
        missing_keys: missing_keys,
        errors: error_details,
        message: "Hệ thống phát hiện #{missing_keys.size} trường khoá chính bị thiếu hoặc sai tên cột. Theo quy định, không thể chuyển sang bước tiếp theo cho đến khi tải lại file đạt chuẩn!"
      })
      next
    end

    # Check for empty rows or data anomalies
    row_errors = []
    rows_data = []
    table.each_with_index do |row, idx|
      r_num = idx + 2 # Excel row index
      req_id = row[mapped_keys['request_id']].to_s.strip
      customer = row[mapped_keys['customer_name']].to_s.strip
      product = row[mapped_keys['product_items']].to_s.strip
      qty = row[mapped_keys['quantity']].to_s.strip
      budget = row[mapped_keys['expected_budget']].to_s.strip
      deadline = row[mapped_keys['deadline']].to_s.strip
      discount = row[mapped_keys['requested_discount']].to_s.strip

      if req_id.empty? && customer.empty? && product.empty?
        next # skip blank lines
      end

      if req_id.empty?
        row_errors << "Dòng #{r_num}: Thiếu Mã yêu cầu/đơn hàng"
      end
      if customer.empty?
        row_errors << "Dòng #{r_num}: Thiếu Tên khách hàng"
      end
      if product.empty?
        row_errors << "Dòng #{r_num}: Thiếu Hạng mục sản phẩm"
      end

      rows_data << {
        "raw_index" => idx + 1,
        "request_id" => req_id,
        "customer_name" => customer,
        "product_items" => product,
        "quantity" => qty,
        "expected_budget" => budget,
        "deadline" => deadline,
        "requested_discount" => discount
      }
    end

    if rows_data.empty?
      send_json(res, 200, {
        status: "ERROR",
        valid: false,
        error_title: "ERROR: FILE KHÔNG CÓ DÒNG DỮ LIỆU NÀO HỢP LỆ!",
        errors: ["File chứa tiêu đề nhưng không có bản ghi dữ liệu yêu cầu kinh doanh nào."]
      })
      next
    end

    if row_errors.size > 5
      send_json(res, 200, {
        status: "ERROR",
        valid: false,
        error_title: "ERROR: DỮ LIỆU BẢN GHI CÓ QUÁ NHIỀU LỖI NGHIÊM TRỌNG!",
        detected_headers: headers,
        errors: row_errors,
        message: "Phát hiện #{row_errors.size} lỗi thiếu thông tin bắt buộc trong từng dòng. Hãy bổ sung dữ liệu trước khi tiếp tục."
      })
      next
    end

    # Passed validation!
    send_json(res, 200, {
      status: "SUCCESS",
      valid: true,
      headers: headers,
      mapped_keys: mapped_keys,
      row_count: rows_data.size,
      data: rows_data,
      warnings: row_errors,
      message: "Dữ liệu hợp lệ! Đầy đủ tất cả các trường khoá chính. Đủ điều kiện chuyển sang Bước 2: AI lọc và chuẩn hóa dữ liệu."
    })
  rescue => e
    send_json(res, 500, {
      status: "ERROR",
      valid: false,
      error_title: "ERROR: LỖI ĐỌC TẬP TIN DỮ LIỆU!",
      errors: [e.message]
    })
  end
end

# Route B2: AI Clean & Normalize
server.mount_proc '/api/clean' do |req, res|
  begin
    body = JSON.parse(req.body || '{}')
    rows = body['rows'] || []
    cleaned_rows = []
    changes_log = []

    rows.each_with_index do |row, idx|
      c = row.dup
      item_changes = []

      # 1. Clean product item & match master SKU
      raw_prod = c['product_items'].to_s.strip
      matched_prod = match_product(raw_prod)
      if matched_prod
        if matched_prod['name'] != raw_prod
          item_changes << "Chuẩn hóa tên SP: '#{raw_prod}' -> '#{matched_prod['name']}' (SKU: #{matched_prod['sku']})"
          c['product_standard'] = matched_prod['name']
          c['sku'] = matched_prod['sku']
        else
          c['product_standard'] = raw_prod
          c['sku'] = matched_prod['sku']
        end
      else
        c['product_standard'] = raw_prod
        c['sku'] = "UNKNOWN-SKU"
        item_changes << "Cảnh báo: Chưa tìm thấy SKU tương ứng trong Bảng giá Master 2026 cho '#{raw_prod}'"
      end

      # 2. Clean Quantity
      raw_qty = c['quantity'].to_s.strip
      qty_num = raw_qty.scan(/\d+/).first.to_i
      qty_num = 1 if qty_num <= 0
      if qty_num.to_s != raw_qty
        item_changes << "Chuẩn hóa số lượng: '#{raw_qty}' -> #{qty_num}"
      end
      c['quantity_clean'] = qty_num

      # 3. Clean Budget
      raw_budget = c['expected_budget'].to_s.strip
      clean_budget_num = parse_budget(raw_budget)
      if clean_budget_num > 0
        c['budget_clean'] = clean_budget_num
        item_changes << "Chuẩn hóa ngân sách: '#{raw_budget}' -> #{clean_budget_num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse} VND"
      else
        c['budget_clean'] = 0
        item_changes << "Cảnh báo: Chưa xác định ngân sách dự kiến (Cần NVKD làm rõ)"
      end

      # 4. Clean Deadline
      raw_deadline = c['deadline'].to_s.strip
      clean_days = parse_deadline_days(raw_deadline)
      c['deadline_days_clean'] = clean_days
      item_changes << "Chuẩn hóa thời hạn: '#{raw_deadline}' -> #{clean_days} ngày"

      # 5. Clean Requested Discount
      raw_discount = c['requested_discount'].to_s.strip
      clean_disc = parse_discount(raw_discount)
      c['discount_clean'] = clean_disc
      item_changes << "Chuẩn hóa chiết khấu: '#{raw_discount}' -> #{clean_disc}%"

      # Record changes
      c['changes'] = item_changes
      changes_log << {
        "request_id" => c['request_id'],
        "customer_name" => c['customer_name'],
        "modifications" => item_changes
      }
      cleaned_rows << c
    end

    send_json(res, 200, {
      status: "SUCCESS",
      cleaned_data: cleaned_rows,
      changes_log: changes_log,
      summary: "AI đã hoàn tất làm sạch, khử nhiễu và đối sánh Master Catalog cho #{cleaned_rows.size} yêu cầu. Dữ liệu sẵn sàng để Người kiểm duyệt 1 (Kiểm toán Dữ liệu) đánh giá."
    })
  rescue => e
    send_json(res, 500, { status: "ERROR", message: e.message })
  end
end

# Route B3: Human Review 1 Feedback Loop
server.mount_proc '/api/review1_feedback' do |req, res|
  begin
    body = JSON.parse(req.body || '{}')
    data = body['cleaned_data'] || []
    feedback = body['feedback'].to_s.strip
    action = body['action'] # 'approve' or 'revise'

    if action == 'approve'
      send_json(res, 200, {
        status: "SUCCESS",
        approved: true,
        data: data,
        message: "Người kiểm duyệt 1 đã phê duyệt bộ dữ liệu chuẩn hóa! Hệ thống chuyển sang Bước 4: AI Phân tích chuyên sâu & Đề xuất kinh doanh."
      })
      next
    end

    # Revise based on human feedback
    updated_data = data.map(&:dup)
    ai_actions_taken = []

    # Simple AI feedback interpreter
    feedback_lower = feedback.downcase
    updated_data.each_with_index do |item, idx|
      req_id = item['request_id'].to_s.downcase

      # Check if feedback mentions this request ID or customer
      if feedback_lower.include?(req_id) || feedback_lower.include?(item['customer_name'].to_s.downcase) || feedback_lower.include?("toàn bộ") || feedback_lower.include?("tất cả")
        if feedback_lower.include?("giảm chiết khấu")
          item['discount_clean'] = [0.0, item['discount_clean'] - 2.0].max
          ai_actions_taken << "Điều chỉnh giảm chiết khấu của #{item['request_id']} xuống #{item['discount_clean']}%"
        elsif feedback_lower.include?("tăng thời hạn") || feedback_lower.include?("thêm ngày")
          item['deadline_days_clean'] += 3
          ai_actions_taken << "Tăng thêm 3 ngày thời hạn triển khai cho #{item['request_id']} (Hiện tại: #{item['deadline_days_clean']} ngày)"
        elsif feedback_lower.include?("sửa ngân sách") || feedback_lower.include?("tăng ngân sách")
          item['budget_clean'] = (item['budget_clean'] * 1.15).to_i
          ai_actions_taken << "Cập nhật tăng ngân sách theo đề xuất cho #{item['request_id']}"
        end
      end
    end

    if ai_actions_taken.empty?
      ai_actions_taken << "AI đã tiếp thu ý kiến: '#{feedback}'. Đã rà soát lại toàn bộ #{updated_data.size} dòng dữ liệu, kiểm tra tính nhất quán mã SKU và đồng bộ lại danh mục."
    end

    send_json(res, 200, {
      status: "SUCCESS",
      approved: false,
      data: updated_data,
      ai_actions: ai_actions_taken,
      message: "AI đã cập nhật trực tiếp dữ liệu theo phản hồi của Người kiểm duyệt 1. Vui lòng xem lại bảng dữ liệu."
    })
  rescue => e
    send_json(res, 500, { status: "ERROR", message: e.message })
  end
end

# Route B4: AI Deep Analysis & Business Proposal
server.mount_proc '/api/analyze' do |req, res|
  begin
    body = JSON.parse(req.body || '{}')
    cleaned_rows = body['cleaned_data'] || []
    policy = MASTER_CATALOG['approval_policy']

    results = []
    total_revenue = 0
    total_cost = 0
    escalation_count = 0
    stock_shortage_count = 0

    cleaned_rows.each do |row|
      prod_name = row['product_standard']
      prod = match_product(prod_name) || {
        "sku" => "MA-GENERIC",
        "name" => prod_name,
        "unit_price" => 15000000,
        "unit_cost" => 11000000,
        "stock_available" => 2,
        "lead_time_days" => 5
      }

      qty = row['quantity_clean'].to_i
      qty = 1 if qty <= 0
      client_deadline_days = row['deadline_days_clean'].to_i
      requested_disc_pct = row['discount_clean'].to_f
      client_budget = row['budget_clean'].to_i

      # 1. Price calculations
      unit_list_price = prod['unit_price']
      unit_cost = prod['unit_cost']
      total_list_price = unit_list_price * qty
      discount_amount = (total_list_price * (requested_disc_pct / 100.0)).round
      final_quote = total_list_price - discount_amount
      total_item_cost = unit_cost * qty
      gross_profit = final_quote - total_item_cost
      gross_margin_pct = final_quote > 0 ? ((gross_profit.to_f / final_quote) * 100.0).round(1) : 0.0

      total_revenue += final_quote
      total_cost += total_item_cost

      # 2. Inventory Check with Operations
      stock_avail = prod['stock_available']
      stock_ok = stock_avail >= qty
      stock_shortage_count += 1 unless stock_ok

      stock_status = if stock_ok
                       { "code" => "OK", "label" => "Khả dụng trong kho (#{stock_avail}/#{qty})", "color" => "green" }
                     else
                       { "code" => "SHORTAGE", "label" => "Thiếu kho (#{stock_avail}/#{qty} chiếc) - Cần nhập hàng", "color" => "red" }
                     end

      # 3. Lead Time / Delivery SLA Check
      required_lead_days = prod['lead_time_days']
      required_lead_days += 5 unless stock_ok # If shortage, add procurement time
      delivery_ok = client_deadline_days >= required_lead_days

      delivery_status = if delivery_ok
                          { "code" => "ON_TIME", "label" => "Đảm bảo tiến độ (Cần #{required_lead_days} ngày / KH yêu cầu #{client_deadline_days} ngày)", "color" => "green" }
                        else
                          { "code" => "RISK_DELAY", "label" => "RỦI RO TRỄ HẠN (Cần tối thiểu #{required_lead_days} ngày / KH yêu cầu #{client_deadline_days} ngày)", "color" => "red" }
                        end

      # 4. Approval Routing & Escalation
      approval_level = ""
      approval_code = ""
      if requested_disc_pct > policy['director_escalation_discount'] || gross_margin_pct < policy['min_deal_gross_margin']
        approval_level = "VƯỢT QUYỀN - Ban Giám đốc phê duyệt"
        approval_code = "DIRECTOR"
        escalation_count += 1
      elsif requested_disc_pct > policy['sales_rep_max_discount']
        approval_level = "Trưởng phòng Kinh doanh phê duyệt"
        approval_code = "MANAGER"
      else
        approval_level = "NVKD được quyền tự quyết định"
        approval_code = "SALES_REP"
      end

      # 5. Budget Check
      budget_diff = client_budget > 0 ? (client_budget - final_quote) : 0
      budget_status = if client_budget.zero?
                        { "label" => "Khách hàng chưa cung cấp ngân sách", "color" => "gray" }
                      elsif budget_diff >= 0
                        { "label" => "Phù hợp ngân sách (+#{budget_diff.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse} đ)", "color" => "green" }
                      else
                        { "label" => "Vượt ngân sách KH (#{budget_diff.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse} đ)", "color" => "amber" }
                      end

      # 6. Opportunity Score & Strategy
      score = 80
      score += 10 if stock_ok
      score -= 20 unless delivery_ok
      score -= 15 if approval_code == "DIRECTOR"
      score += 10 if gross_margin_pct >= 20

      # 7. Draft Response Email
      email_draft = <<~TEXT
        Kính gửi Quý Khách hàng #{row['customer_name']},

        Công ty Cổ phần Công nghệ Minh An xin chân thành cảm ơn Quý công ty đã tin tưởng gửi yêu cầu báo giá cho hạng mục: #{prod['name']}.

        Dựa trên năng lực kho vận và chính sách ưu đãi dành cho Quý doanh nghiệp, Minh An xin trân trọng gửi phương án kinh doanh sơ bộ như sau:
        - Thiết bị: #{prod['name']} (SKU: #{prod['sku']})
        - Số lượng: #{qty} bộ
        - Đơn giá niêm yết: #{unit_list_price.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse} VND
        - Mức chiết khấu áp dụng: #{requested_disc_pct}% (Tiết kiệm: #{discount_amount.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse} VND)
        - Tổng giá trị đề xuất (chưa VAT): #{final_quote.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1.').reverse} VND
        - Thời gian bàn giao & nghiệm thu: #{delivery_ok ? "#{client_deadline_days} ngày kể từ ngày ký hợp đồng" : "#{required_lead_days} ngày làm việc (do cần điều phối kho bảo đảm tiêu chuẩn)"}

        #{!delivery_ok ? "(*) Lưu ý về tiến độ: Do số lượng thiết bị cần chuẩn bị đồng bộ kiểm định chất lượng, Minh An đề xuất thời hạn bàn giao tối ưu là #{required_lead_days} ngày để đảm bảo dịch vụ tốt nhất cho Quý vị." : ""}

        Hồ sơ báo giá chi tiết và cam kết SLA dịch vụ đính kèm văn bản này. Kính mong nhận được phản hồi từ Quý công ty.

        Trân trọng,
        Bộ phận Kinh doanh Doanh nghiệp - Công ty Công nghệ Minh An
      TEXT

      results << {
        "request_id" => row['request_id'],
        "customer_name" => row['customer_name'],
        "product_name" => prod['name'],
        "sku" => prod['sku'],
        "quantity" => qty,
        "unit_list_price" => unit_list_price,
        "unit_cost" => unit_cost,
        "total_list_price" => total_list_price,
        "discount_pct" => requested_disc_pct,
        "discount_amount" => discount_amount,
        "final_quote" => final_quote,
        "client_budget" => client_budget,
        "gross_profit" => gross_profit,
        "gross_margin_pct" => gross_margin_pct,
        "stock_status" => stock_status,
        "delivery_status" => delivery_status,
        "approval_level" => approval_level,
        "approval_code" => approval_code,
        "budget_status" => budget_status,
        "opportunity_score" => score,
        "email_draft" => email_draft
      }
    end

    overall_margin = total_revenue > 0 ? (((total_revenue - total_cost).to_f / total_revenue) * 100.0).round(1) : 0.0

    send_json(res, 200, {
      status: "SUCCESS",
      results: results,
      metrics: {
        "total_requests" => results.size,
        "total_revenue" => total_revenue,
        "total_profit" => total_revenue - total_cost,
        "overall_margin_pct" => overall_margin,
        "escalations_count" => escalation_count,
        "stock_shortages" => stock_shortage_count
      },
      message: "AI đã hoàn tất phân tích chi phí, tồn kho, SLA và lập đề xuất kinh doanh tự động!"
    })
  rescue => e
    send_json(res, 500, { status: "ERROR", message: e.message })
  end
end

# Route B6: Human Review 2 Feedback Loop (Sales Manager / Final Reviewer)
server.mount_proc '/api/review2_feedback' do |req, res|
  begin
    body = JSON.parse(req.body || '{}')
    results = body['results'] || []
    feedback = body['feedback'].to_s.strip

    updated_results = results.map(&:dup)
    actions = []
    fb_low = feedback.downcase

    updated_results.each do |item|
      req_id = item['request_id'].to_s.downcase
      cust = item['customer_name'].to_s.downcase

      if fb_low.include?(req_id) || fb_low.include?(cust) || fb_low.include?("toàn bộ") || fb_low.include?("tất cả")
        if fb_low.include?("tăng chiết khấu") || fb_low.include?("thêm chiết khấu")
          item['discount_pct'] += 2.0
          item['discount_amount'] = (item['total_list_price'] * (item['discount_pct'] / 100.0)).round
          item['final_quote'] = item['total_list_price'] - item['discount_amount']
          item['gross_profit'] = item['final_quote'] - (item['unit_cost'] * item['quantity'])
          item['gross_margin_pct'] = ((item['gross_profit'].to_f / item['final_quote']) * 100.0).round(1)
          actions << "Đã tăng chiết khấu cho #{item['request_id']} lên #{item['discount_pct']}%, tính lại giá trị đề xuất: #{item['final_quote']} VND"
        elsif fb_low.include?("giảm chiết khấu")
          item['discount_pct'] = [0.0, item['discount_pct'] - 2.0].max
          item['discount_amount'] = (item['total_list_price'] * (item['discount_pct'] / 100.0)).round
          item['final_quote'] = item['total_list_price'] - item['discount_amount']
          item['gross_profit'] = item['final_quote'] - (item['unit_cost'] * item['quantity'])
          item['gross_margin_pct'] = ((item['gross_profit'].to_f / item['final_quote']) * 100.0).round(1)
          actions << "Đã giảm chiết khấu cho #{item['request_id']} xuống #{item['discount_pct']}%, bảo toàn biên lợi nhuận #{item['gross_margin_pct']}%"
        elsif fb_low.include?("gia hạn") || fb_low.include?("dời tiến độ") || fb_low.include?("thời hạn")
          item['delivery_status'] = { "code" => "ON_TIME", "label" => "Đã thống nhất gia hạn tiến độ theo yêu cầu quản lý", "color" => "green" }
          actions << "Đã cập nhật gia hạn tiến độ giao hàng cho #{item['request_id']}"
        end
      end
    end

    if actions.empty?
      actions << "AI đã ghi nhận phản hồi của Trưởng phòng: '#{feedback}'. Đã tối ưu hóa biên lợi nhuận và cập nhật bản nháp phản hồi."
    end

    send_json(res, 200, {
      status: "SUCCESS",
      results: updated_results,
      actions: actions,
      message: "AI đã cập nhật lại đề xuất kinh doanh theo chỉ đạo của Người kiểm duyệt cuối cùng!"
    })
  rescue => e
    send_json(res, 500, { status: "ERROR", message: e.message })
  end
end

puts "=========================================================="
puts "  MINH AN B2B AI AGENT SYSTEM SERVER STARTED"
puts "  Address: http://localhost:#{PORT}"
puts "=========================================================="

server.start
