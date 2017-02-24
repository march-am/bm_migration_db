require 'open-uri'
require 'nokogiri'
require 'mechanize'
require 'json'
require 'sqlite3'
require 'csv'
require 'capybara/dsl'
require 'capybara/poltergeist'
require 'timeout'

# NokogiriしきれないのでCapybaraを入れる

require './setting'
# ログイン用ID/PASS用ファイル
# mail = 'mail@mail.com'
# passwd = 'pass'

# リニューアル対応版

# $DEBUG = 1
$log = Logger.new(STDOUT)
$log.level = Logger::DEBUG

Capybara.configure do |config|
  config.run_server = false
  config.current_driver = :poltergeist
  config.javascript_driver = :poltergeist
  config.app_host = 'https://elk.bookmeter.com/'
  config.default_max_wait_time = 5
  config.automatic_reload = false
end

Capybara.register_driver :poltergeist do |app|
  Capybara::Poltergeist::Driver.new(app, {:js_errors => false, :timeout => 5000 })
end

class BookInfo

  include Capybara::DSL

  def initialize
      @agent = Mechanize.new do |agent|
        agent.user_agent_alias = 'Windows IE 7'
      end
      # @dbfile = 'bookdata.db'
      @userid = ''
      @base_url = 'https://elk.bookmeter.com'
      @my_url = @base_url + '/users' + @userid
      @login_url = @base_url + '/login'
      @list_type = ["read", "reading", "stacked", "wish"] # 読んだ, 読んでる, 積読, 読みたい
      @w_org = 1  # 1=>オリジナル含む 0=>含まない
  end

  # GetInfo

  def login
    page.driver.headers = { 'User-Agent' => 'Mac Safari' }

    if page.driver.browser.cookies.empty?
      $log.debug("started login.")
      visit @login_url
      page.find("input[name='session[email_address]']").send_keys $mail
      page.find("input[name='session[password]']").send_keys $passwd
      page.find("button[name='button']").click
      $log.debug("finished login.")
    else
      $log.debug("already logged in.")
    end
  end

  def get_user_id

    if @userid.empty?
        @session.visit(@base_url + '/home')
        a = @session.find(:xpath, "//dt[@class='user-profiles__avatar']/a/@href")
        @userid = a.to_s[7..-1]
    end
    $log.debug("id is #{@userid}")

  end

  def crawl_all_ID
    bIDs = []

    @list_type.each do |type|
        list_url = @my_url + '/' + (@userid).to_s + '/books/' + type
        html = @agent.get(list_url)
        page_max = get_page_max(html)
        $log.debug("#{type}'s pagemax is #{page_max}.")
        (1..page_max).each do |i|
            each_list_url = list_url + '?page=' + i.to_s
            page = get_nokogiri_doc(each_list_url)
            page.search("//div[@class='thumbnail__cover']/a/@href").each do |node|
                bID = node.to_s[7..-1]
                bIDs.push(bID)
            end
            $log.debug("crawled #{type}-page#{i}.")
            sleep(1)
        end
        $log.debug("crawled all page of #{type}.")
    end
    bIDs.uniq
    $log.debug("crawled all ID.")
  end

  def get_page_max(html)
    saigo = html.search("//ul[@class='pagination']/li[last()]/a/@href").to_s
    max = $1.to_i if saigo =~ /.*page=(\d+)$/
    max = 1 if max == nil || max == ''
    return max
  end

  def get_nokogiri_doc(url)
    begin
      if $DEBUG
        html = open(url, :proxy => 'http://localhost:5432')
      else
        html = open(url)
      end
    rescue OpenURI::HTTPError
      return
    end
    Nokogiri::HTML(html, nil, 'utf-8')
  end

  def fetch_bookdata_json(ids)
    bookdata = []
    # 本ごとの情報取得
    ids.each_with_index do |id, idx|
        # wait_for_ajax
        each_book_url = @base_url + '/books/' + id
        page.visit each_book_url

        begin
          _bookdata = page.find("div.read-book__action > div > div")['data-modal']
          _bookdata = JSON.parse(_bookdata)
        rescue Capybara::ElementNotFound => e
          _bookdata = {}
        end

        _bookdata['status'] = get_book_status # 0 読んだ < 1 読んでる < 2 積読 <  3 読みたい
        bookdata.push _bookdata
        # { "read_book_id":59720696,
        #   "author":"野崎まど",
        #   "pages":169,
        #   "book":{
        #     "id":7324376,
        #     "asin":"4150311307", <- null ならオリジナル本
        #     "title":"ファンタジスタドール イヴ (ハヤカワ文庫JA)",
        #     "image_url":"https://images-na.ssl-images-amazon.com/images/I/51E4gppU5nL._SL120_.jpg"
        #   },
        #   "review":{
        #     "text":"レビュー",
        #     "is_netabare":false,
        #     "read_at":"2016-10-16",
        #     "is_draft":false
        #   },
        #   "bookcases":["SF","☆5","中編","小説"],
        #   "id":"js_modal_bd4910540a26ea4f0ebfee8286b81dc0",
        #   'status': [0, 1, 3]
        # }
    end
    bookdata
  end

  def get_book_status
    status = []
    doc = Nokogiri::HTML(page.html)
    classes = doc.search(:xpath, "//section[@class='sidebar__group']/div[2]/ul/li/@class")
    classes.each_with_index do |st, idx|
      status.push(idx) if st.to_s.include?('active')
    end
    status
  end

  def scrape
    login
    ids = ['5148925'] # crawl_all_ID
    bookinfos = fetch_bookdata_json(ids)
    $log.debug(bookinfos)
    # crawlInfo = crawl_info(crawlID)
  end

  def wait_for_ajax
    Timeout.timeout(Capybara.default_max_wait_time) do
      active = page.evaluate_script('jQuery.active')
      until active == 0
        active = page.evaluate_script('jQuery.active')
      end
    end
  end

end
#class BookInfo end

bi = BookInfo.new
bi.scrape
