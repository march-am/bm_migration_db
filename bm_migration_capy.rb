require 'open-uri'
require 'nokogiri'
require 'mechanize'
require 'json'
# require 'sqlite3'
require 'csv'
require 'capybara/dsl'
require 'capybara/poltergeist'
# require 'timeout'

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
      @user_id = ''
      @base_url = 'https://elk.bookmeter.com'
      @my_url = @base_url + '/users' + @user_id
      @login_url = @base_url + '/login'
      @list_type = ["read", "reading", "stacked", "wish"] # 読んだ, 読んでる, 積読, 読みたい
      @w_org = 1  # 1=>オリジナル含む 0=>含まない
  end

  def get_nokogiri_doc(url)
    begin
      if $DEBUG
        html = open(url) #, :proxy => 'http://localhost:5432')
      else
        html = open(url)
      end
    rescue OpenURI::HTTPError
      return
    end
    Nokogiri::HTML(html, nil, 'utf-8')
  end

  def get_nokogiri_doc_from_html(html)
    Nokogiri::HTML(html, nil, 'utf-8')
  end

  def wait_for_ajax
    Timeout.timeout(Capybara.default_max_wait_time) do
      active = page.evaluate_script('jQuery.active')
      until active == 0
        active = page.evaluate_script('jQuery.active')
        sleep(0.5)
      end
    end
  end

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
    if @user_id.empty?
        visit(@base_url + '/home')
        a = page.find('dt.user-profiles__avatar > a')['href']
        @user_id = a.to_s.gsub('https://elk.bookmeter.com/users/','')
        # https://elk.bookmeter.com/users/*****
    end
    $log.debug("id is #{@user_id}")
  end

  def fetch_ids
    bIDs = []

    @list_type.each do |type|
        list_url = @my_url + '/' + (@user_id).to_s + '/books/' + type
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
            $log.debug("fetch #{type}-page#{i}.")
            sleep(1)
        end
        $log.debug("fetch all page of [#{type}].")
    end
    bIDs.uniq!
    $log.debug("fetch all ID: #{bIDs}")
    return bIDs
  end

  def get_page_max(html)
    saigo = html.search("//ul[@class='pagination']/li[last()]/a/@href").to_s
    max = $1.to_i if saigo =~ /.*page=(\d+)$/
    max = 1 if max == nil || max == ''
    return max
  end

  def fetch_bookdata_json(ids)
    bookdata = []
    # 本ごとの情報取得
    ids.each_with_index do |id, idx|
        # wait_for_ajax
        each_book_url = @base_url + '/books/' + id
        page.visit each_book_url
        doc = get_nokogiri_doc_from_html(page.html)

        begin
          json = doc.search("//div[@class='read-book__action']/div/div/@data-modal").to_s
          # 「読んだ本」に登録されていない場合
          json = doc.search("//section[@class='sidebar__group']/div[2]/ul/li[1]/div/@data-modal").to_s if json.empty?
        rescue Capybara::ElementNotFound => e
            $log.debug("書籍情報が取得できませんでした。book_id: #{id}")
        end
        json = json.gsub(/[\r\n]/m, '' )
        _bookdata = JSON.parse(json)
        _bookdata['status'] = get_book_status # 0 読んだ < 1 読んでる < 2 積読 <  3 読みたい
        bookdata.push _bookdata
    end
    bookdata
  end

  def get_book_status
    status = []
    doc = get_nokogiri_doc_from_html(page.html)
    classes = doc.search("//section[@class='sidebar__group']/div[2]/ul/li/@class")
    classes.each_with_index do |st, idx|
      status.push(idx) if st.to_s.include?('active')
    end
    status
  end

  def load_text(text_path)
    File.open(text_path, 'r') do |f|
      return f.readlines
    end
  end

  def save_to_text(bookdatas, text_path)
    File.open(text_path, 'w') do |f|
      f.puts bookdatas
    end
    $log.debug("(#{text_path}) is saved.")
 end

  def scrape
    login
    get_user_id
    ids = ["11121227", "8134811"] #fetch_ids
    text_path = "#{@user_id}_book_ids_#{Time.now.strftime('%F')}.txt"
    # t = load_text(text_path)
    bookdatas = fetch_bookdata_json(ids)
    save_to_text(bookdatas, text_path)
    return bookdatas
  end

  def convert(bookdatas, service)
    out = []
    text_path = "#{@user_id}_#{service}_#{Time.now.strftime('%F')}.csv"
    case service
    # when 'bookmeter'     then out = temp_BM(bookdatas)
    when 'biblia'             then out = temp_biblia(bookdatas)
    when 'mediamarker' then out = temp_mediamarker(bookdatas)
    when 'debug'            then out = temp_debug(bookdatas)
    else
      puts '正しいサービスIDを指定してください'
    end
    p out
    # save_to_text(out, text_path)
    $log.debug("#{text_path} is saved!")
  end

  # def temp_BM(bookdatas)
  #   out = []
  #   div = 100 #100ずつ分けた方がいい？
  #     (0..@book_n).each do |i|
  #         rdate = "#{books[i][:ry]}-#{books[i][:rm]}-#{books[i][:rd]} 00:00:00"
  #         case books[i][:st].max
  #             when 4 then status = '読み終わった'
  #             when 3 then status = 'いま読んでる'
  #             when 2 then status = '積読'
  #             when 1 then status = '読みたい'
  #             else status = ''
  #         end
  #         out << ['1', books[i][:bookID], '', category, books[i][:rrank], status, books[i][:review], books[i][:tag], books[i][:memo], rdate, rdate]
  #         # puts "#{i+1}冊取得"
  #     out
  #   end
  # end

  def temp_biblia(bookdatas)
    out = []
    ndate = Time.now.strftime("%D")
    bookdatas.each do |book|
      case book['status'].max
          # 本棚(0)/読みたい(1)
          when 4, 3 ,2 then status = 0
          when 1 then status = 1
          else status = 1
      end
      title = book['book']['title']
      author = book['book']['author']
      rdate = book['book']['review'].nil? ? '' : book['book']['review']['read_at'].gsub('-','/')
      rank = book['book']['bookcases'].nil? ? '' : book['book']['bookcases'].select{ |i| i.include?('☆') }.gsub('☆','').to_i
      isbn13 = 'dummy' #convert_asin_to_isbn13(book['book']]['asin'])
      review = book.has_key?(:text) ? book['book']['review']['text'] : ''
      image_url = book.has_key?(:image_url) ? book['book']['image_url'] : ''
      store_url = book.has_key?(:amazon_url) ? book['book']['amazon_url'] : ''

      out << [ title, '', author, '', '', isbn13, rdate, '', review, image_url, store_url, ndate, status, rank ]
      #タイトル, タイトル仮名(※未使用), 著者, 著者仮名(※未使用), 出版社, ISBN-13, 日付(yyyy/MM/dd), メモ, 感想, 表紙画像URL, 楽天商品リンク, データ登録日(yyyy/mm/dd), 本棚(0)/読みたい(1), 星評価(0〜5)
      #http://webservice.rakuten.co.jp/api/bookstotalsearch/をたたけば書影なども取れそう
    end
    out
  end

  def temp_mediamarker(bookdatas)
    out = []
    div = 100 #100ずつ分けた方がいい？
    (0..book_n).each do |i|
        rdate = "読了: #{books[i][:ry]}年#{books[i][:rm]}月#{books[i][:rd]}日"
        t = [books[i][:st], books[i][:review], books[i][:memo], rdate].join(', ')
        out << [books[i][:bookID], t]
    end
    out
  end

  def temp_debug(bookdatas)
    out = bookdatas[0]
  end

  def convert_asin_to_isbn13
    #
  end

end
#class BookInfo end

bi = BookInfo.new
# bookdatas = bi.scrape
bookdatas = []
p bi.convert(bookdatas, 'biblia')
