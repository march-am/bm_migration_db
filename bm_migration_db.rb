require 'open-uri'
require 'nokogiri'
require 'mechanize'
require 'json'
require 'sqlite3'
require 'csv'

require 'bm_id' # ログイン用ID/PASS用 (mail, passwd)

# リニューアル対応版

dbfile = 'bookdata.db'

userid = ''
base_url = 'https://elk.bookmeter.com'
my_url = base_url + '/users/' + userid
login_url = base_url + '/login'
list_type = ["read", "reading", "stacked", "wish"] # 読んだ, 読んでる, 積読, 読みたい
w_org = 1  # 1=>オリジナル含む 0=>含まない
agent = Mechanize.new
agent.user_agent_alias = 'Windows IE 7'

db = SQLite3::Database.new(dbfile)
# csv = CSV.open('bookID.csv', "r:windows-31j", force_quotes: true)
#
# db.transaction do
#   csv.each {|v| db.execute('INSERT into book_ids (bookID) values (?)', v) }
# end
# # 切断
# db.close

class BookInfo

  # GetInfo
  def login_BM
    agent.get(login_url) do |page|
        page.form_with(:action => '/login') do |form|
            form.field_with(:name => 'mail').value = mail
            form.field_with(:name => 'password').value = password
        end.submit
    end
    if userid.empty?
        page = agent.get(base_url + "/home")
        userid = page.search("//a[@class='account__personal']/@href").to_s[8..-1]
    end
  end

  def crawl_all_ID
    bIDs = []

    list_type.each do |type|
        list_url = my_url + '/books/' + type
        html = agent.get(list_url).content.toutf8
        page_max = $1.to_i if html.body =~ /&p=(\d+)\">最後/
        page_max = 1 if page_max == nil || page_max == ''

        (1..page_max).each do |i|
            each_list_url = list_url + '?page=' + i.to_s
            page = get_nokogiri_doc(each_list_url)
            page.search("//div[@class='thumbnail__cover']/a/@href").each do |node|
                bID = node.to_s[8..-1]
                bIDs.push(bID)
            end
            sleep(1)
        end
    end
    bIDs.uniq
  end

  def get_nokogiri_doc(url)
    begin
      html = open(url)
    rescue OpenURI::HTMLError
      return
    end
    Nokogiri::HTML(html, nil, 'utf-8')
  end

  def get_ID_diff
    #oldIDsとCrawlAllIDを比較、差分を取得
    @diffID = []
    @isExistIDDiff = false
  end

  def add_ID_to_DB
    #
  end

  def crawl_info(bookIDs)
    books = []
    bookIDs.flatten!
    @book_n = bookIDs.length - 1

    # 本ごとの情報取得
    (0..@book_n).each do |i|
        each_book_url = base_url + '/books/' + bookIDs[i]
        page = get_nokogiri_doc(each_book_url)

        _bookdata = page.search("//div[@class='action__edit']/div/@data-modal").gsub(/&quot;/,'"')
        unless _bookdata.empty?
          bookdata = JSON.parse(_bookdata)
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
          #   "id":"js_modal_bd4910540a26ea4f0ebfee8286b81dc0" }
        else
          bookdata = page.search("//div[@class='books sidebar']/section[1]/div[2]/ul/li[1]/div/@data-modal").gsub(/&quot;/,'"')
        # { "book":{
        #     "id":10161392,
        #     "asin":"4839956758",
        #     "title":"フロントエンドエンジニアのための現在とこれからの必須知識",
        #     "author":"斉藤 祐也,水野 隼登,谷 拓樹,菅原 のびすけ,林 優一,古沢 宏太",
        #     "page":224,
        #     "book_path":"/books/10161392",
        #     "image_url":"https://images-na.ssl-images-amazon.com/images/I/51iaxDyyhgL._SL120_.jpg",
        #     "amazon_url":"https://www.amazon.co.jp/dp/product/(略)
        #   },
        #   "id":"js_modal_15c5187b040ce64b6a1b108e946e5ccd" }
        end

        ss, st = [],[]
        page.search("//section[@class='sidebar__group']/div[2]/ul/li/@class").each {|node| ss.push(node.text)}
        st.push(4) if ss =~ /active/
        st.push(3) if ss =~ /active/
        st.push(2) if ss =~ /active/
        st.push(1) if ss =~ /active/ #考えとく
        # 読んだ < 読んでる < 積読 < 読みたい

        title = ''
        author = page.search("//ul[@class='header__authors']/li/a/text()").to_s
        date = bookdata[:date] # 不明のとき調べる
        ry = date[0..-1].to_i
        rm = date[5..-1].to_i
        rd = date[8..-1].to_i

        # rf = page.search("//input[@name='fumei']/@checked").to_s
        # unless rf == "checked" #「不明」にチェックマークが入っていない
        #    ry = format("%02d", page.search("//select[@id='read_date_y']/option[1]/@value").to_s.to_i)
        #    rm = format("%02d", page.search("//select[@id='read_date_m']/option[1]/@value").to_s.to_i)
        #    rd = format("%02d", page.search("//select[@id='read_date_d']/option[1]/@value").to_s.to_i)
        # else
        #     ry = "0000"
        #     rm = rd = "00"
        # end

        tag = bookdata['bookcase'].to_a
        rrank = $1 if tag =~ /☆(\d)/
        memo = tag.to_s + " (from #{each_book_url})" #コメントを取得して入れたいが難しそう

        books[i] = { #構造をBMにあわせえう？
            bookID: bookIDs[i], #ASIN ISBN-13にしたいが…。
            title: bookdata["book"]["title"],
            author: author,
            page: bookdata["pages"],
            cover: bookdata["book"]["image_url"],
            review: bookdata["review"]["text"],
            netabare: bookdata["review"]["is_netabare"],
            rrank: rrank, #(1-5)
            st: st, #(1-4) 4読んだ 3読んでる 2積読 1読みたい
            tag: tag, #array
            memo: memo,
            ry: ry, rm: rm, rd: rd
        }
        sleep(0.5)
    end
    books
  end

  def add_info_to_DB
    @diffInfo = []
    @isExistInfoDiff = false
  end

  def crawl
    login_BM
    allID = crawl_all_ID
    crawlID
    get_ID_diff
    if @isExistIDDiff
      crawlID = @diffID
    else
      crawlID = allID
    end
    add_ID_to_DB(crawlID)
    crawlInfo = crawl_info(crawlID)
    add_info_to_DB(crawlInfo)
  end

  def conv_asin_to_isbn13(asin)
  end

  #ConvInfo
  def info_to_array
  end

  def convert_style(service)
    case service
    when 'bookmeter'   then temp_BM
    when 'biblia'      then temp_biblia
    when 'mediamarker' then temp_mediamarker
    when 'debug'       then temp_debug
    else
      puts '正しいサービスIDを指定してください'
    end
  end

  def temp_BM
    out = []
    @div = 100 #100ずつ分けた方がいい？
      (0..@book_n).each do |i|
          rdate = "#{books[i][:ry]}-#{books[i][:rm]}-#{books[i][:rd]} 00:00:00"
          case books[i][:st].max
              when 4 then status = '読み終わった'
              when 3 then status = 'いま読んでる'
              when 2 then status = '積読'
              when 1 then status = '読みたい'
              else status = ''
          end
          out << ['1', books[i][:bookID], '', category, books[i][:rrank], status, books[i][:review], books[i][:tag], books[i][:memo], rdate, rdate]
          # puts "#{i+1}冊取得"
      out
    end
  end

  def temp_biblia
    out = []
    ndate = Time.now.strftime("%D")
    (0..book_n).each do |i|
        rdate = "#{books[i][:ry]}/#{books[i][:rm]}/#{books[i][:rd]}"
        case books[i][:st].max
            when 4, 3 ,2 then status = 0
            when 1 then status = 1
            else status = 1
        end
        books[i][:rrank] == "" || books[i][:rrank] == nil ? rrank = 0 : rrank = books[i][:rrank].to_i
        isbn = conv_asin_to_isbn13(books[i][isbn])

        out << [books[i][:title], '', books[i][:author], '', '', isbn13, rdate, books[i][:memo], books[i][:review], '', '', ndate, status, rrank]
        #タイトル, タイトル仮名(※未使用), 著者, 著者仮名(※未使用), 出版社, ISBN-13, 日付(yyyy/MM/dd), メモ, 感想, 表紙画像URL, 楽天商品リンク, データ登録日(yyyy/mm/dd), 本棚(0)/読みたい(1), 星評価(0〜5)
        #http://webservice.rakuten.co.jp/api/bookstotalsearch/をたたけば書影なども取れそう
    end
    out
end

  def temp_mediamarker
    out = []
    @div = 100 #100ずつ分けた方がいい？
    (0..book_n).each do |i|
        rdate = "読了: #{books[i][:ry]}年#{books[i][:rm]}月#{books[i][:rd]}日"
        t = [books[i][:st], books[i][:review], books[i][:memo], rdate].join(', ')
        out << [books[i][:bookID], t]
    end
    out
  end

  def temp_debug
    out = books[1]
  end

  # SaveInfo
  def save_CSV
  end

end
