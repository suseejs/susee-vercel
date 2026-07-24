# frozen_string_literal: true

require "jekyll"
require "json"
require "pathname"

module Jekyll
  # module Jekyll::ShikiCodeBlock
  module ShikiCodeBlock
    class << self
      def site_config(site_or_config)
        return {} unless site_or_config
        return site_or_config.config if site_or_config.respond_to?(:config)

        site_or_config
      end

      def site_source(site_or_config)
        return site_or_config.source if site_or_config.respond_to?(:source)

        site_config(site_or_config)["source"] || Dir.pwd
      end

      def get_or_start_node_process(site)
        return @node_io if defined?(@node_io) && !@node_io.closed?

        script_path = resolve_shiki_bundle_path(site)
        @node_io = IO.popen(["node", script_path], "r+")
        @node_io.sync = true
        @node_io
      end

      def shiki_plugin_config(site)
        site_config(site).fetch("shiki_code_block", {})
      end

      def resolve_shiki_bundle_path(site)
        bundle_path = shiki_plugin_config(site)["bundle_path"]
        return File.expand_path("../node/shiki.js", __dir__) unless bundle_path
        return bundle_path if Pathname.new(bundle_path).absolute?

        File.expand_path(bundle_path, site_source(site))
      end

      def shiki_highlight(code, lang, site) # rubocop:disable Metrics/MethodLength
        plugin_config = shiki_plugin_config(site)
        io = get_or_start_node_process(site)

        input_data = JSON.generate({
          code: code,
          lang: lang,
          theme: plugin_config["theme"]
        }.compact)

        io.puts(input_data)
        response_line = io.gets
        raise "Shiki highlight pipeline broke unexpectedly" if response_line.nil?

        response = JSON.parse(response_line)
        raise "Shiki highlight failed: #{response["error"]}" if response["error"]

        response["html"]
      end

      def create_wrapper(lang, code, site)
        lang_label = lang.to_s.capitalize
        highlighted_code = shiki_highlight(code, lang, site)
        <<~HTML
          <div class="shiki_code" data-shiki-highlighter>
            <div class="code_head">
              <span>#{lang}</span>
              <button type="button" aria-label="Highlight-#{lang_label}" data-copy-btn></button>
            </div>
            #{highlighted_code}
          </div>
        HTML
      end
    end
  end

  # Override Jekyll's default Kramdown handler
  module Converters
    class Markdown
      class KramdownShiki < KramdownParser
        def initialize(config)
          @site_config = config
          super
        end

        def convert(content)
          Thread.current[:jekyll_site_config] = @site_config

          document = Kramdown::JekyllDocument.new(content, @config)
          html_output = document.to_shiki_html
          if @config["show_warnings"]
            document.warnings.each do |warning|
              Jekyll.logger.warn "Kramdown warning:", warning
            end
          end
          html_output
        ensure
          Thread.current[:jekyll_site_config] = nil
        end
      end
    end
  end
end

module Kramdown
  module Converter
    class ShikiHtml < Html
      def convert_codeblock(el, indent)
        lang = extract_code_language(el)
        code = el.value

        site_config = Thread.current[:jekyll_site_config]
        Jekyll::ShikiCodeBlock.create_wrapper(lang, code, site_config)
      end

      private

      def extract_code_language(el) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
        # 1. Check if kramdown explicitly stored a parsed language option
        return el.options[:lang].to_s if el.options && el.options[:lang] && !el.options[:lang].to_s.empty?

        # 2. Fallback check for raw classes added inside code block braces
        attr = el.attr || {}
        if attr["class"]
          classes = attr["class"].split
          lang_class = classes.find { |c| c.start_with?("language-") }
          return lang_class.sub("language-", "") if lang_class
        end

        "text"
      end
    end
  end
end

# Register the new HTML converter with the Kramdown engine core
class Kramdown::Document
  def to_shiki_html
    Kramdown::Converter::ShikiHtml.convert(@root, @options).first
  end
end

# Safely close the pipe when the system exits
at_exit do
  if defined?(Jekyll::ShikiCodeBlock) && Jekyll::ShikiCodeBlock.instance_variable_defined?(:@node_io)
    io = Jekyll::ShikiCodeBlock.instance_variable_get(:@node_io)
    io.close unless io.closed?
  end
end
