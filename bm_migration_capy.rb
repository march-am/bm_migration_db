require 'open-uri'
require 'nokogiri'
require 'mechanize'
require 'json'
require 'csv'
require 'capybara/dsl'
require 'capybara/poltergeist'
# require 'timeout'

require './setting'
# ログイン用ID/PASS用ファイル
# $mail   = 'mail@mail.com'
# $passwd = 'pass'

$log = Logger.new(STDOUT)
$log.level = Logger::DEBUG

Capybara.configure do |config|
  config.run_server = false
  config.current_driver = :poltergeist
  config.javascript_driver = :poltergeist
  config.app_host = 'https://elk.bookmeter.com/'
  config.default_max_wait_time = 10
  config.automatic_reload = false
end

Capybara.register_driver :poltergeist do |app|
  Capybara::Poltergeist::Driver.new(app, {:js_errors => false, :timeout => 5000 })
end

class String
  def sjisable
    str = self
    #変換テーブル上の文字を下の文字に置換する
    from_chr = "\u{301C 2212 00A2 00A3 00AC 2013 2014 2016 203E 00A0 00F8 203A}"
    to_chr   = "\u{FF5E FF0D FFE0 FFE1 FFE2 FF0D 2015 2225 FFE3 0020 03A6 3009}"
    str.tr!(from_chr, to_chr)
    #変換テーブルから漏れた不正文字は?に変換し、さらにUTF8に戻すことで今後例外を出さないようにする
    str = str.encode("Windows-31J","UTF-8",:invalid => :replace,:undef=>:replace).encode("UTF-8","Windows-31J")
  end
end #http://qiita.com/yugo-yamamoto/items/0c12488447cb8c2fc018

class BookInfo

  include Capybara::DSL

  def initialize
      # @dbfile = 'bookdata.db'
      @user_id = ''
      @base_url = 'https://elk.bookmeter.com'
      @my_url = @base_url + '/users' + @user_id
      @login_url = @base_url + '/login'
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
      $log.info("finished login.")
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

  def fetch_bookdatas
    list_type = ['read', 'reading', 'stacked', 'wish'] # 読んだ, 読んでる, 積読, 読みたい
    datas = []

    list_type.each do |type|
      first_list_url = @my_url + '/' + @user_id + '/books/' + type
      page_max = get_page_max(first_list_url)
      $log.debug("[#{type}] has #{page_max} pages.")
      page_max = 2

      if type == 'read'
        xpath = "//div[@class='detail__edit']/div/@data-modal"
        status = 0
      else
        xpath = "//section[@id='modals']/@data-modal"
        case type
        when 'reading' then status = 1
        when 'stacked' then status = 2
        when 'wish'    then status = 3
        end
      end

      (1..page_max).each do |i|
        each_list_url = first_list_url + '?page=' + i.to_s
        each_list_url = first_list_url + '?display_type=list&page=' + i.to_s if type == 'read'
        page = get_nokogiri_doc(each_list_url)
        save_and_open_page
        page.search(xpath).each do |data|
          json = data.to_s.gsub(/[\r\n]/m, '')
          json = JSON.parse(json)
          json['status'] = status
          $log.debug("data: #{json}")
          datas.push(json)
        end
        $log.debug("fetched [#{type}: page #{i}].")
        sleep(1)
      end
      $log.debug("fetched all page of [#{type}].")
    end

    return datas = uniquefy_data(datas)
    $log.info("fetched all data.")
  end

  def get_page_max(url)
    visit url
    begin
      saigo = find_link('最後')['href']
      max = $1.to_i if saigo =~ /.*page=(\d+)$/
    rescue Capybara::ElementNotFound => e
      max = 2 #念のため2ページまで拾ってみる
    end
    return max
  end

  def uniquefy_data(datas)
    # a) datas(array).each do |data| data['book']['id'] が同じかどうか。同じなら book['status'] が大きい方を削除。
    # b) data['book']['id']とbook['status']をキーにソート。その後、一つ前のデータと比較して同じidを持ってれば＝book['status'] が大きい方を削除。
    datas
  end

  def scrape
    login
    get_user_id
    bookdatas = fetch_bookdatas
  end

  def load_text(path)
    if File.exist?(path)
      arr = []
      File.open(path, 'r') do |f|
        f.each_line do |line|
          arr << eval(line)
        end
      end
      return arr
    else
      $log.error("#{path} does not exist!")
      exit(1)
    end
  end

  def save_to_text(bookdatas, path)
    if File.exist?(path)
      $log.error("#{path}というファイルは存在します。上書き(o)、別名で保存(r)、中止(c)")
      while true
        response = gets
        case response
          when /^[oO]/
            File.open("#{path}.txt", 'w') do |f|
              f.puts bookdatas
            end
            $log.info("#{path}.txt を上書保存しました。")
            break
          when /^[rR]/
            $log.info("新しいファイル名前を入力してください (例: #{path}_2)")
            new_path = gets.chop
            save_to_text(bookdatas, new_path)
            break
          when /^[cC]/
            $log.info("処理は中止されました。")
            exit(0)
            break
          else
            $log.info("o/r/c のどれかを入力してください。")
            next
        end
      end
    else
      File.open("#{path}.txt", 'w') do |f|
        f.puts bookdatas
      end
      $log.info("#{path}.txt を保存しました。")
    end
  end

  def save_to_csv(lines, path)
    # if File.exist?(text_path)
    #   $log.error("#{text_path} already exists.")
    # else
      CSV.open("#{path}.csv", "w:windows-31j", force_quotes: true) do |file|
        lines.each { |row| file << row }
      end
      $log.info("#{path}.csv is saved.")
    # end
  end

  def save_bookdatas(bookdatas)
    text_path = "#{@user_id}_bookdata_#{Time.now.strftime('%F')}"
    # t = load_text(text_path)
    save_to_text(bookdatas, text_path)
  end

  def save_chunks_to_csv(bookdatas, data_each_chunk, path, service)
    book_num = bookdatas.size
    chunk_num = (book_num / data_each_chunk).to_i
    (0..chunk_num).each do |ci| # data_each_chunk個ずつファイルを分割
      start_n = 100 * ci
      if start_n + 99 <= book_num
        end_n = start_n + 99
      else
        end_n = book_num - start_n
      end
      range = bookdatas[start_n..end_n]
      lines = send("temp_#{service}", range)
      text_path = "#{path}_#{'%02d' % ci}"
      save_to_csv(lines, text_path)
    end
  end

  def convert_and_save_bookdatas(bookdatas, service)
    lines = []
    text_path = "#{@user_id}_#{service}_#{Time.now.strftime('%F')}"

    case service
      when 'booklog'
        save_chunks_to_csv(bookdatas, 100, text_path, 'booklog')
      when 'mediamarker'
        save_chunks_to_csv(bookdatas, 100, text_path, 'mediamarker')
      when 'biblia'
        lines = temp_biblia(bookdatas)
        save_to_csv(lines, text_path)
      when 'debug'
        lines = temp_debug(bookdatas)
      else
        puts '正しいサービスIDを指定してください'
        exit(1)
    end
  end

  def temp_biblia(bookdatas)
    out = []
    ndate = Time.now.strftime("%D")
    bookdatas.each do |book|
      case book['status'].max # 本棚(0)/読みたい(1)
        when 4, 3, 2 then status = 0
        when 1 then       status = 1
        else              status = 1
      end
      title     = book['book']['title']
      author    = book['author']
      isbn13    = book['book']['asin'] #convert_asin_to_isbn13(book['book']]['asin'])
      rdate     = book['review']['read_at'].nil?  ? '' : book['review']['read_at'].gsub('-','/')
      tag       = book['bookcases'].nil?          ? '' : book['bookcases']
      review    = book['review']['text'].nil?     ? '' : book['review']['text']
      image_url = book['book']['image_url'].nil?  ? '' : book['book']['image_url']
      store_url = book['book']['amazon_url'].nil? ? '' : book['book']['amazon_url']
      r         = tag.select{ |i| i.include?('☆') }
      rank      = r[0].to_s.gsub('☆','').to_i

      out << [title, nil, author, nil, nil, isbn13, rdate, tag, review, image_url, store_url, ndate, status, rank]
      #タイトル, タイトル仮名(※未使用), 著者, 著者仮名(※未使用), 出版社, ISBN-13, 日付(yyyy/MM/dd), メモ=>タグ, 感想, 表紙画像URL, 楽天商品リンク, データ登録日(yyyy/mm/dd), 本棚(0)/読みたい(1), 星評価(0〜5)
    end
    return out
  end

  def temp_booklog(bookdatas)
    out = []
    ndate = Time.now.strftime("%D")
    bookdatas.each do |book|
      case book['status'].max
        when 4 then status_text = '読み終わった'
        when 3 then status_text = 'いま読んでる'
        when 2 then status_text = '積読'
        when 1 then status_text = '読みたい'
        else        status_text = ''
      end
      asin   = book['book']['asin']
      isbn13 = convert_asin_to_isbn13(asin)
      tag    = book['bookcases'].nil? ? '' : book['bookcases']
      r      = tag.select{ |i| i.include?('☆') }
      rank   = r[0].to_s.gsub('☆','').to_i
      review = book['review']['text'].nil? ? '' : book['review']['text'].sjisable
      rdate  = "#{book['review']['read_at']} 00:00:00"

      out << ['1', asin, nil, '-', rank, status_text, review, tag, nil, ndate, rdate]
      # サービスID[1=Amzn], アイテムID, 13桁ISBN, カテゴリ, 評価, 読書状況, レビュー, タグ, 読書メモ(非公開), 登録日時, 読了日
    end
    return out
  end

  def temp_mediamarker(bookdatas)
    out = []
    bookdatas.each do |book|
      case book['status'].max
        when 4 then status_text = '読み終わった'
        when 3 then status_text = 'いま読んでる'
        when 2 then status_text = '積読'
        when 1 then status_text = '読みたい'
        else        status_text = ''
      end
      asin    = book['book']['asin']
      tag     = book['bookcases'].nil? ? '' : book['bookcases'].join('、')
      comment = "#{status_text}／#{book['review']['text']}／#{tag}／読了:#{book['review']['read_at']}"
      out << [asin, comment]
    end
    return out
  end

  def temp_debug(bookdatas)
    out = bookdatas[0]
  end

  def convert_asin_to_isbn13(asin) #AmazonAPI使って変換
    isbn13 = asin
    return isbn13
  end

end
#class BookInfo end

bi = BookInfo.new
bookdatas = bi.scrape
p bookdatas
