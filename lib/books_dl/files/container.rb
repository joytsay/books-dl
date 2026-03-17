require "nokogiri"

module BooksDL
  module Files
    class Container < ::BooksDL::BaseFile
      attr_reader :root_file_path

      def initialize(path, content)
        super(path, content)

        doc = Nokogiri::XML(content)
        doc.remove_namespaces!

        rootfile = doc.at_css("rootfile")
        raise "Invalid container.xml. First 500 chars:\n#{content.to_s[0, 500]}" unless rootfile

        @root_file_path = rootfile["full-path"]
      end
    end
  end
end
