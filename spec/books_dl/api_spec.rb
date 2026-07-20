describe BooksDL::API do
  subject(:api) { described_class.allocate }

  let(:download_token) { 'token+/=' }
  let(:info) do
    OpenStruct.new(
      download_link: 'https://streaming-ebook.books.com.tw/V1.0/Streaming/bookII/E55837/9897747',
      download_token: download_token,
      encrypt_type: 'enc01'
    )
  end
  let(:response) { Struct.new(:body).new('encrypted') }

  before do
    allow(api).to receive(:info).and_return(info)
    allow(BooksDL::Utils).to receive(:generate_key).and_return([1])
    allow(BooksDL::Utils).to receive(:decode_xor).and_return('decoded')
  end

  it 'uses the BookDownLoadURLII endpoint' do
    expect(described_class::BOOK_DL_URL).to end_with('/BookDownLoadURLII')
  end

  it 'recognizes a viewer cookie session without launching a browser' do
    api.instance_variable_set(
      :@current_cookie,
      'CmsToken' => 'cms', 'DownloadToken' => 'download', 'bid' => 'book-id', 'ssid' => 'session-id'
    )

    expect(api.send(:ebook_session?)).to be true
  end

  it 'recognizes an unencrypted free-book session without DownloadToken' do
    api.instance_variable_set(
      :@current_cookie,
      'CmsToken' => 'cms', 'bid' => 'book-id', 'ssid' => 'session-id'
    )

    expect(api.send(:ebook_session?)).to be true
  end

  it 'requests book info with an encoded ID and a millisecond timestamp' do
    allow(api).to receive(:info).and_call_original
    api.instance_variable_set(:@book_id, 'E123_reflowable_normal&ran=ignored')
    api.instance_variable_set(
      :@current_cookie,
      'CmsToken' => 'cms', 'DownloadToken' => 'download', 'bid' => 'book-id', 'ssid' => 'session-id'
    )
    allow(api).to receive(:login)
    allow(api).to receive(:register_device)
    expect(api).to receive(:get) do |url|
      query = URI.decode_www_form(URI.parse(url).query).to_h
      expect(URI.parse(url).path).to end_with('/BookDownLoadURLII')
      expect(query['book_uni_id']).to eq 'E123_reflowable_normal&ran=ignored'
      expect(query['t']).to match(/\A\d{13}\z/)
      Struct.new(:body).new('{"download_link":"https://example.test/","download_token":"token"}')
    end

    expect(api.info.download_token).to eq 'token'
  end

  it 'reports API errors before attempting a resource request' do
    allow(api).to receive(:info).and_call_original
    api.instance_variable_set(:@book_id, 'E123_trial')
    api.instance_variable_set(
      :@current_cookie,
      'CmsToken' => 'cms', 'bid' => 'book-id', 'ssid' => 'session-id'
    )
    allow(api).to receive(:login)
    allow(api).to receive(:register_device)
    allow(api).to receive(:get).and_return(
      Struct.new(:body).new('{"error_code":"id_err_203","error_message":"Device not Existed"}')
    )

    expect { api.info }.to raise_error(RuntimeError, /id_err_203.*Device not Existed/)
  end

  it 'requires the browser Local Storage device ID for a copied cookie session' do
    api.instance_variable_set(
      :@current_cookie,
      'CmsToken' => 'cms', 'bid' => 'book-id', 'ssid' => 'session-id'
    )

    expect { api.send(:register_device) }.to raise_error(RuntimeError, /device_id.*Local Storage/)
  end

  it 'registers the device with the current GET endpoint' do
    api.instance_variable_set(:@current_cookie, {})
    api.instance_variable_set(:@device_id, 'browser-device-id')
    expect(api).to receive(:get) do |url, _headers|
      expect(URI.parse(url).path).to end_with('/DeviceReg')
      expect(URI.decode_www_form(URI.parse(url).query).to_h['device_id']).to eq 'browser-device-id'
      Struct.new(:body).new('{}')
    end

    api.send(:register_device)
  end

  it 'uses the raw token for metadata and decrypts it' do
    expect(api).to receive(:get) do |url|
      expect(url).to include('/META-INF/container.xml?DownloadToken=token%2B%2F%3D')
      response
    end

    expect(api.fetch('META-INF/container.xml')).to eq 'decoded'
  end

  it 'uses a YA token for regular resources and decrypts them' do
    allow(BooksDL::Utils).to receive(:ya_token).with(download_token, 'OEBPS/story.xhtml').and_return('signed-token')
    expect(api).to receive(:get)
      .with(/OEBPS\/story\.xhtml\?DownloadToken=signed-token\z/)
      .and_return(response)

    expect(api.fetch('OEBPS/story.xhtml')).to eq 'decoded'
  end

  it 'downloads audio with a YA token without XOR decoding' do
    allow(BooksDL::Utils).to receive(:ya_token).with(download_token, 'OEBPS/audio.mp3').and_return('signed-token')
    expect(api).to receive(:get).with(/DownloadToken=signed-token\z/).and_return(response)
    expect(BooksDL::Utils).not_to receive(:decode_xor)

    expect(api.fetch('OEBPS/audio.mp3')).to eq 'encrypted'
  end

  it 'downloads fonts without a token or XOR decoding' do
    expect(api).to receive(:get)
      .with('https://streaming-ebook.books.com.tw/V1.0/Streaming/bookII/E55837/9897747/OEBPS/font.woff2')
      .and_return(response)
    expect(BooksDL::Utils).not_to receive(:ya_token)
    expect(BooksDL::Utils).not_to receive(:decode_xor)

    expect(api.fetch('/OEBPS/font.woff2')).to eq 'encrypted'
  end
end
