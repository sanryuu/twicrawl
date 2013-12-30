#! /usr/bin/env ruby -Ku

require 'bundler'
Bundler.require
require 'twitter'
require 'json'
require 'open-uri'
require 'pp'
require 'yaml'

# 設定ファイルの読み込み
config = YAML.load_file("config.yml")

PICT_SAVE_PATH =    config["path"]["pic_save"]
TMP_MID_FILE_PATH = config["path"]["tmp_mid_file"]

DOWNLOAD_INTERVAL     = config["interval"]["download"].to_i
DOWNLOAD_LIMIT_RETRY  = config["limit"]["download"].to_i
TWITTER_API_INTERVAL  = config["interval"]["twitter_api"].to_i
TWITTER_LIMIT_RETRY   = config["limit"]["twitter_api"].to_i
GLOBAL_RETRY_INTERVAL = config["interval"]["global"].to_i
GLOBAL_LIMIT_RETRY    = config["limit"]["global"].to_i

CONSUMER_KEY =    config["api"]["consumer"]["key"]
CONSUMER_SECRET = config["api"]["consumer"]["secret"]

ACCESS_TOKEN_KEY = config["api"]["access"]["token_key"]
ACCESS_SECRET =    config["api"]["access"]["secret"]



def collect_with_max_id(collection=[], max_id=nil, &block)
  response = yield max_id
  collection += response
  response.empty? ? collection.flatten : collect_with_max_id(collection, response.last.id - 1, &block)
end

def get_all_tweets(user,include_rts=true)
  try_count = 1
  begin
    collect_with_max_id do |max_id|
      options = {:count => 200, :include_rts => include_rts}
      options[:max_id] = max_id unless max_id.nil?
      @client.user_timeline(user, options)
    end
  rescue => e
    return if try_count > TWITTER_LIMIT_RETRY
    print "API LIMIT WAIT! #{try_count}\n"
    sleep_time = TWITTER_API_INTERVAL * try_count
    print "API LIMIT WAIT! retry:#{try_count} sleep:#{sleep_time}s\n"
    util_sleep(sleep_time)
    try_count += 1
    retry
  end
end

# 画像取得
def get_all_pict_url(user,include_rts=true)
  urls = Array.new
  get_all_tweets(user,include_rts).each do |tweet|
    unless tweet.to_h[:entities][:media].nil?
      tweet.to_h[:entities][:media].each do |media|
        urls << media[:media_url]
      end
    end
  end
  return urls
end

# ユーザ情報を抜粋
def register(uid)
  user = @client.user(uid)

  extracted = Hash.new
  extracted[:name] = user[:name]
  extracted[:screen_name] = user[:screen_name]
  extracted[:description] = user[:description]
  extracted[:image]  = user[:profile_image_url].to_str unless user[:profile_image_url].nil?
  extracted[:banner] = user[:profile_banner_url].to_str unless user[:profile_banner_url].nil?
  return extracted

end


# 画像保存関数
def save_pic(user,pic)

  Dir.mkdir(PICT_SAVE_PATH + user[:screen_name], 0777) unless Dir.exist?(PICT_SAVE_PATH + user[:screen_name])

  file_name = pic.scan(/.{15}?\..{3,4}$/)[0]
  # 15: Twitterにupされる画像のファイル名のHash長
  # 3,4: 拡張子の長さ

  try_count = 1
  begin
    src = open(pic)
  rescue => e
    print e.message + "\n"
    # 画像が壊れている場合
    if e.message == "403 Forbidden"
      return
    end
    if e.message == "404 Not Found"
      return
    end

    return if try_count > DOWNLOAD_LIMIT_RETRY
    sleep_time = DOWNLOAD_INTERVAL * try_count
    print "DOWNLOAD LIMIT WAIT! retry:#{try_count} sleep:#{sleep_time}s\n"
    util_sleep(sleep_time)
    try_count += 1
    retry
  end

  dst = open(PICT_SAVE_PATH + user[:screen_name] + "/" + file_name, "wb")
  dst.write(src.read())
end

# --------------------------------------------------------------------
#  Util
# --------------------------------------------------------------------

# 途中データの保存
def save_mid_data(save_data)
  print "save #{save_data}\n"
  foo = File.open(TMP_MID_FILE_PATH, 'w')
  foo.puts JSON.generate(save_data)
  foo.close
end
# 途中データの読み込み
def load_mid_data()
  save_data = Hash.new
  open(TMP_MID_FILE_PATH) do |io|
    save_data = JSON.load(io)
  end
  return save_data
rescue => e
  return save_data
end

def util_sleep(time)
  part = time.to_f / 20
  print "SLEEP #{part} * 20\n"
  print "[                    ]\n["
  20.times do
    print "-"
    sleep(part)
  end
  print "]\n"
end

# ======================================================================



# Twitter.configure 設定
@client = Twitter::REST::Client.new do |config|
  config.consumer_key       = CONSUMER_KEY
  config.consumer_secret    = CONSUMER_SECRET
  config.oauth_token        = ACCESS_TOKEN_KEY
  config.oauth_token_secret = ACCESS_SECRET
end

# フォローしているユーザのID一覧を取得
followd_uids = @client.friend_ids.attrs[:ids]

# ユーザ数の表示
print "followed number is #{followd_uids.length}\n"

# --------------------------------------------------------------------
# ダウンロード
# --------------------------------------------------------------------
load_data = load_mid_data
print "LOAD\n"
pp load_data

mid_point = false
followd_number = followd_uids.length
user_count = 0


followd_uids.each do |uid|
  try_count = 1
  begin
    # 初期化
    user_count += 1                 # ユーザカウント
    user = register(uid)            # ユーザ情報の取得

    # 途中開始の指定
    if user[:screen_name] == load_data["last_download_user"]
      mid_point = true
      next
    end
    unless mid_point
      print "SKIP USER  #{user_count}/#{followd_number} :: #{user[:screen_name]}\n"
      next
    end
    picts = get_all_pict_url(uid)   # 画像URLの取得  (画像を含むTweetObjectにする予定)



    # 現状把握の表示
    print "START #{user_count}/#{followd_number} :: #{user[:screen_name]}\n"

    # ダウンロード処理
    length = picts.length
    count = 0
    picts.each do |pic|
      print "DL: #{user[:screen_name]}  #{count}/#{length} #{pic}\n"
      save_pic(user,pic)
      sleep(0.5)
      count = count + 1
    end
    print "DONE #{user_count}/#{followd_number} :: #{user[:screen_name]}\n"
    save_data = Hash.new
    save_data["last_download_user"] = user[:screen_name]
    save_mid_data(save_data)

    print "wait 30s\n"
    util_sleep(30)

  rescue => e
    print e.message + "\n"
    return if try_count > GLOBAL_LIMIT_RETRY
    print "GLOBAL LIMIT WAIT! #{try_count}\n"
    sleep_time = GLOBAL_RETRY_INTERVAL * try_count
    print "GLOBAL LIMIT WAIT! retry:#{try_count} sleep:#{sleep_time}s\n"
    util_sleep(sleep_time)
    try_count += 1
    retry
  else
    try_count = 1
  end

end
