require_relative './lib/books_dl'


# 如何取得 book_id
# 進入你要下載的書的閱讀頁面，取得網址列中網址
# 例如：
#   https://viewer-ebook.books.com.tw/viewer/epub/web/?book_uni_id=E050096232_reflowable_normal&ran=97991701
# book_uni_id= 之後的字串就是這本書的 book_id 了
#
book_id = 'E050096232_reflowable_normal&ran=97991701'
downloader = BooksDL::Downloader.new(book_id)
downloader.perform