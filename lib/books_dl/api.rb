require 'selenium-webdriver'

module BooksDL
  class API
    attr_reader :current_cookie, :book_id, :device_id

    COOKIE_FILE_NAME = 'cookie.json'.freeze
    EBOOK_SESSION_COOKIE_NAMES = %w[CmsToken bid ssid].freeze
    NO_AUTH_EXTENSIONS = %w[.ttc .otf .ttf .eot .woff .woff2].freeze
    BINARY_EXTENSIONS = %w[.mp3 .m4a .wav .ogg].freeze

    # API ENDPOINTS
    #
    # rubocop:disable Metrics/LineLength
    CART_URL = 'https://db.books.com.tw/shopping/cart_list.php'.freeze
    LOGIN_HOST = 'https://cart.books.com.tw'.freeze
    LOGIN_PAGE_URL = "https://cart.books.com.tw/member/login?url=#{CART_URL}".freeze
    LOGIN_ENDPOINT_URL = 'https://cart.books.com.tw/member/login_do/'.freeze

    DEVICE_REG_URL = 'https://appapi-ebook.books.com.tw/V1.7/CMSAPIApp/DeviceReg'.freeze
    OAUTH_URL = 'https://appapi-ebook.books.com.tw/V1.7/CMSAPIApp/LoginURL?type=&device_id=&redirect_uri=https%3A%2F%2Fviewer-ebook.books.com.tw%2Fviewer%2Flogin.html'.freeze
    OAUTH_ENDPOINT_URL = 'https://appapi-ebook.books.com.tw/V1.7/CMSAPIApp/MemberLogin?code='.freeze
    BOOK_DL_URL = 'https://appapi-ebook.books.com.tw/V1.7/CMSAPIApp/BookDownLoadURLII'.freeze
    # rubocop:enable Metrics/LineLength

    def initialize(book_id)
      @book_id = book_id
      load_existed_cookies
    end

    def fetch(path)
      url = "#{info.download_link.to_s.sub(%r{/+\z}, '')}/#{path.to_s.sub(%r{\A/+}, '')}"
      ext = File.extname(path).downcase

      if NO_AUTH_EXTENSIONS.include?(ext) || info.encrypt_type == 'none'
        get(url).body.to_s
      else
        token = metadata_path?(path) ? info.download_token : Utils.ya_token(info.download_token, path)
        resp = get(with_download_token(url, token))
        return resp.body.to_s if BINARY_EXTENSIONS.include?(ext)

        key = Utils.generate_key(url, info.download_token)
        Utils.decode_xor(key, resp.body.to_s)
      end
    end

    # return Struct of [:book_uni_id, :download_link, :download_token, :size, :encrypt_type]
    def info
      @info ||= begin
        login
        register_device
        create_ebook_session unless ebook_session?

        query = URI.encode_www_form(book_uni_id: book_id, t: (Time.now.to_f * 1000).to_i)
        resp = get("#{BOOK_DL_URL}?#{query}")
        data = JSON.parse(resp.body.to_s)
        validate_download_info!(data)
        OpenStruct.new(data)
      end
    end

    def login
      return if ebook_session? || logged?
      # 試著先用 Selenium 自動登入
      if login_with_slider_captcha
        puts "🎉 使用 Selenium 自動登入成功"
        return
      end
      # 傳統方式 fallback
      puts "⚠️ Selenium 失敗，改用人工輸入驗證碼模式"
      username, password = get_account_from_stdin
      login_page = get(LOGIN_PAGE_URL).body.to_s
      captcha = get_captcha_from(login_page)

      data = { form: { captcha: captcha, login_id: username, login_pswd: password } }
      headers = {
        'Host': 'cart.books.com.tw',
        'Referer': 'https://cart.books.com.tw/member/login',
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-Requested-With': 'XMLHttpRequest'
      }

      post(LOGIN_ENDPOINT_URL, data, headers)
      return if logged?

      puts "#{'-' * 10} 登入失敗，請再試一次 #{'-' * 10}\n"
      login
    end

    def logged?
      @logged = begin
        response = get(CART_URL)

        response.status == 200
      end
    end

    private

    def ebook_session?
      EBOOK_SESSION_COOKIE_NAMES.all? do |name|
        current_cookie[name].is_a?(String) && !current_cookie[name].empty?
      end
    end

    def create_ebook_session
      current_cookie.reject! { |key| %w[CmsToken redirect_uri normal_redirect_uri DownloadToken].include?(key) }

      puts '透過 OAuth 取得 CmsToken...'
      resp = get(OAUTH_URL)
      login_uri = JSON.parse(resp.body.to_s).fetch('login_uri')
      code = get(login_uri).headers['Location'].split('&code=').last
      get("#{OAUTH_ENDPOINT_URL}#{code}")
    end

    def register_device
      if ebook_session? && device_id.to_s.empty?
        raise 'cookie.json 缺少 device_id；請從閱讀器網域的 Local Storage 複製 device_id'
      end

      @device_id ||= SecureRandom.uuid
      data = {
        device_id: device_id,
        language: 'zh-TW',
        os_type: 'WEB',
        os_version: default_headers[:'user-agent'],
        screen_resolution: '1680X1050',
        screen_dpi: 96,
        device_vendor: 'Google Inc.',
        device_model: 'web'
      }
      headers = {
        accept: 'application/json, text/javascript, */*; q=0.01',
        Origin: 'https://viewer-ebook.books.com.tw',
        Referer: 'https://viewer-ebook.books.com.tw/viewer/epub/web/'
      }

      puts '註冊 Fake device 中...'
      query = URI.encode_www_form(data)
      get("#{DEVICE_REG_URL}?#{query}", headers)
    end

    def validate_download_info!(data)
      if data['error_code']
        raise "取得下載資訊失敗：#{data['error_code']} - #{data['error_message']}"
      end

      link = data['download_link'].to_s
      return if link.match?(%r{\Ahttps?://}i)

      raise "取得下載資訊失敗：API 未回傳有效的 download_link（book_id=#{book_id}）"
    end

    def metadata_path?(path)
      File.basename(path).casecmp('container.xml').zero? || File.extname(path).casecmp('.opf').zero?
    end

    def with_download_token(url, token)
      separator = url.include?('?') ? '&' : '?'
      "#{url}#{separator}DownloadToken=#{URI.encode_www_form_component(token)}"
    end

    def load_existed_cookies
      data = JSON.parse(File.read(COOKIE_FILE_NAME))
      @device_id = data.delete('device_id')
      @configured_book_id = data.delete('book_id')
      @current_cookie = data
    rescue StandardError
      @current_cookie = {}
    end

    def get_account_from_stdin
      print('請輸入帳號：')
      username = gets.chomp
      password = STDIN.getpass('請輸入密碼:').chomp
      [username, password]
    end

    def get(url, headers = {})
      headers = build_headers({ Cookie: cookie }, headers)
      response = HTTP.headers(headers).get(url)

      if response.status >= 400
        file_name = URI(url).path.split('/').last
        raise "取得 `#{file_name}` 失敗。 Status: #{response.status}"
      end

      save_cookie(response)
      response
    end

    def post(url, data = {}, headers = {})
      headers = build_headers({ Cookie: cookie }, headers)
      response = HTTP.headers(headers).post(url, data)
      save_cookie(response)

      response
    end

    def save_cookie(response)
      cookie_jar = response.cookies
      cookie_hash = cookie_jar.map { |cookie| [cookie.name, cookie.value] }.to_h
      current_cookie.merge!(cookie_hash)

      saved_data = current_cookie.merge(
        'book_id' => (@configured_book_id || book_id),
        'device_id' => device_id
      ).compact
      cookie_json = JSON.pretty_generate(saved_data)
      File.open(COOKIE_FILE_NAME, 'w') do |file|
        file.write(cookie_json)
      end
    end

    def cookie
      current_cookie.reduce('') { |cookie, (name, value)| cookie + "#{name}=#{value}; " }.strip
    end

    def default_headers
      @default_headers ||= {
        'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_2) ' \
                      'AppleWebKit/537.36 (KHTML, like Gecko) ' \
                      'Chrome/71.0.3578.98 Safari/537.36'
      }
    end

    def build_headers(*args)
      args.reduce(default_headers, &:merge)
    end

    def get_user_input(label)
      puts label

      gets.chomp
    end

    def get_captcha_from(login_page)
      doc = Nokogiri::HTML(login_page)
      captcha_img_path = doc.at_css('#captcha_img > img').attr('src')
      captcha_img_url = "#{LOGIN_HOST}#{captcha_img_path}"

      img = get(captcha_img_url).body
      File.open('captcha.png', 'wb+') { |file| file.write(img) }
      begin
        `open ./captcha.png`
      rescue StandardError
        puts '開啟失敗，請自行查看 captcha.png 檔案。'
      end
      puts '請輸入認證碼 (captcha.png，不分大小寫)：'

      gets.chomp
    end

    def login_with_slider_captcha
      browser_path = ENV['CHROME_BINARY']
      driver_path = ENV['CHROMEDRIVER_PATH']
      profile_dir = Dir.mktmpdir('chromium-selenium-')
      driver = nil

      begin
        options = Selenium::WebDriver::Chrome::Options.new
        options.binary = browser_path unless browser_path.to_s.empty?
        options.add_argument("--user-data-dir=#{profile_dir}")
        options.add_argument('--no-sandbox')
        options.add_argument('--disable-setuid-sandbox')
        options.add_argument('--disable-dev-shm-usage')
        options.add_argument('--disable-gpu')
        options.add_argument('--disable-software-rasterizer')
        options.add_argument('--window-size=1280,800')
        options.add_argument('--remote-debugging-pipe')

        log_path = File.join(Dir.tmpdir, 'chromedriver.log')
        service_options = { args: ['--verbose', "--log-path=#{log_path}"] }
        service_options[:path] = driver_path unless driver_path.to_s.empty?
        service = Selenium::WebDriver::Service.chrome(**service_options)
        driver = Selenium::WebDriver.for(:chrome, options: options, service: service)

        driver.navigate.to(LOGIN_PAGE_URL)
        puts '請在瀏覽器中手動輸入帳號、密碼並完成滑塊驗證，完成後請按 Enter 繼續...'
        STDIN.gets

        @current_cookie ||= {}
        driver.manage.all_cookies.each do |cookie|
          @current_cookie[cookie[:name]] = cookie[:value]
        end

        File.write(COOKIE_FILE_NAME, JSON.pretty_generate(@current_cookie))
        true
      rescue StandardError => e
        puts "[Selenium] 登入失敗：#{e.class} - #{e.message}"
        false
      ensure
        driver.quit if driver
        FileUtils.remove_entry(profile_dir) if Dir.exist?(profile_dir)
      end
    end
  end
end
