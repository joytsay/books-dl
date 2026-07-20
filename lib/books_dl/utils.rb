module BooksDL
  class Utils
    def self.hex_to_byte(hex)
      return [] unless hex.is_a?(String)

      hex.scan(/../).map(&:hex)
    end

    def self.generate_key(url, download_token)
      raise ArgumentError, 'url is nil' if url.nil?
      if download_token.nil? || download_token.empty?
        raise ArgumentError, "download_token is nil or empty for url=#{url.inspect}"
      end

      file_path = extract_file_path(url)

      md5_chars = Digest::MD5.hexdigest(file_path).chars
      partition = md5_chars.each_slice(4).reduce(0) do |num, chars|
        (num + Integer("0x#{chars.join}")) % 64
      end

      decode_hex = Digest::SHA256.hexdigest(
        "#{download_token[0...partition]}#{file_path}#{download_token[partition..]}"
      )

      hex_to_byte(decode_hex)
    end

    # The encryption path starts after /V1.0/Streaming/book[II]. Query
    # parameters must not be included because they change the SHA256 key.
    def self.extract_file_path(url)
      value = url.to_s.split('?', 2).first
      return URI::DEFAULT_PARSER.unescape(value.start_with?('/') ? value : "/#{value}") unless value.match?(%r{\Ahttps?://}i)

      path = URI.parse(value).path
      parts = path.split('/').reject(&:empty?)
      streaming_index = parts.index('Streaming')
      unless streaming_index && parts.length > streaming_index + 2
        raise ArgumentError, "unexpected download url format: #{url}"
      end

      URI::DEFAULT_PARSER.unescape("/#{parts.drop(streaming_index + 2).join('/')}")
    rescue URI::InvalidURIError
      raise ArgumentError, "unexpected download url format: #{url}"
    end

    # Resource requests use the viewer's YA() signature. Metadata files use
    # the raw download token and fonts do not use a token at all.
    def self.ya_token(download_token, path)
      raise ArgumentError, 'download_token is nil or empty' if download_token.nil? || download_token.empty?

      resource_path = path.to_s.sub(%r{\A/+}, '')
      key = (67 * Math.sqrt(resource_path.length)).round.to_s + resource_path
      message = "#{download_token}|#{resource_path}|web"

      OpenSSL::HMAC.hexdigest('SHA256', key, message) + download_token
    end

    def self.decode_xor(key, encrypted_content)
      count = 0
      tmp = []
      bytes = encrypted_content.bytes

      (0...bytes.size).each do |idx|
        tmp[idx] = bytes[idx] ^ key[count]
        count += 1
        count = 0 if count >= key.size
      end

      tmp = tmp[3..] if (tmp[0] == 239) && (tmp[1] == 187) && (tmp[2] == 191)

      result = if tmp.size > 10_000
                 count2 = (tmp.size / 10_000.0).ceil
                 (0...count2).each do |idx|
                   tmp[idx] = tmp[idx * 10_000...(idx + 1) * 10_000]
                 end

                 tmp[0...count2].reduce('') { |str, bytes| str << bytes.pack('c*') }
               else
                 tmp.pack('c*')
               end

      result.force_encoding('utf-8')
    end

    def self.img_checksum
      seed = %w[0 6 9 3 1 4 7 1 8 0 5 5 9 A A C]
      (0...seed.size).each do |idx|
        rand_idx = (0...seed.size).to_a.sample
        seed[idx], seed[rand_idx] = seed[rand_idx], seed[idx]
      end
      seed.join
    end
  end
end
