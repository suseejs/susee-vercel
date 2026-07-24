# frozen_string_literal: true

require "jekyll"
require "json"
require "pathname"

module Jekyll
  # module Jekyll::ShikiCodeBlock
  module ShikiCodeBlock
    class << self
      def get_or_start_node_process(site)
        return @node_io if defined?(@node_io) && !@node_io.closed?

        script_path = resolve_shiki_bundle_path(site)
        @node_io = IO.popen(["node", script_path], "r+")
        @node_io.sync = true
        @node_io
      end

      def shiki_plugin_config(site)
        site ? site.config.fetch("shiki_code_block", {}) : {}
      end

      def resolve_shiki_bundle_path(site)
        bundle_path = shiki_plugin_config(site)["bundle_path"]
        return File.expand_path("../node/shiki.js", __dir__) unless bundle_path
        return bundle_path if Pathname.new(bundle_path).absolute?

        File.expand_path(bundle_path, site.source)
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

      def create_wrapper(lan, code, site)
        lang = lan.to_s.capitalize
        highlighted_code = shiki_highlight(code, lan, site)
        <<~HTML
          <div class="shiki_code" data-shiki-highlighter>
            <div class="code_head">
              <span>#{lan}</span>
              <button type="button" aria-label="Highlight-#{lang}" data-copy-btn></button>
            </div>
            #{highlighted_code}
          </div>
        HTML
      end
    end
  end

  # Override Jekyll's default Kramdown handler
  module Converters
    module Markdown
      # class Jekyll::Converters::Markdown::KramdownShiki
      class KramdownShiki < Converters::Markdown
        def initialize(config)
          super
          @config = config
        end

        def matches(ext)
          ext =~ /^\.(md|markdown)$/i
        end

        def output_ext(ext)
          ".html"
        end

        def convert(content)
          Thread.current[:jekyll_site_config] = @config

          document = Kramdown::Document.new(content, Utils.symbolize_hash_keys(@config["kramdown"]))
          html_output = document.to_shiki_html

          Thread.current[:jekyll_site_config] = nil
          html_output
        end
      end

      # class Jekyll::Converters::Markdown::ShikiHtml
      class ShikiHtml < Html
        def convert_codeblock(ell, indent)
          lang = extract_code_language(ell)
          code = ell.value

          site_config = Thread.current[:jekyll_site_config]
          Jekyll::ShikiCodeBlock.create_wrapper(lang, code, site_config)
        end

        private

        def extract_code_language(ell) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
          # 1. Check if kramdown explicitly stored a parsed language option
          return ell.options[:lang].to_s if ell.options && ell.options[:lang] && !ell.options[:lang].to_s.empty?

          # 2. Fallback check for raw classes added inside code block braces
          attr = ell.attr || {}
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
