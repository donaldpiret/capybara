require 'xpath'

::XPath::Collection.class_eval do
  alias_method :paths, :expressions
end

module Capybara

  ##
  #
  # This is a class for generating XPath queries, use it like this:
  #
  #     Xpath.text_field('foo').link('blah').to_s
  #
  # This will generate an XPath that matches either a text field or a link.
  #
  class XPath

    class << self
      include ::XPath

      def locator
        varstring(:locator)
      end

      def collection(*args)
        ::XPath::Collection.new(*args)
      end

      def link(locator)
        link = descendant(:a).where(attr(:href))
        collection(
          link.where(text.equals(locator) | attr(:title).equals(locator) | descendant(:img).where(attr(:alt).equals(locator))),
          link.where(attr(:id).contains(locator) | contains(locator) | attr(:title).contains(locator) | descendant(:img).where(attr(:alt).contains(locator)))
        ).apply(:locator => locator)
      end

      def button(locator)
        input = descendant(:input).where(attr(:type).one_of('submit', 'image', 'button'))
        button = descendant(:button)
        image = descendant(:input).where(attr(:type).equals('image'))
        collection(
          button.where(attr(:value).equals(locator) | text.equals(locator)),
          input.where(attr(:value).equals(locator)),
          image.where(attr(:alt).equals(locator)),
          input.where(attr(:id).equals(locator) | attr(:value).contains(locator)),
          button.where(attr(:id).equals(locator) | attr(:value).contains(locator) | contains(locator)),
          image.where(attr(:alt).contains(locator))
        ).apply(:locator => locator)
      end

      def escape(string)
        if string.include?("'")
          string = string.split("'", -1).map do |substr|
            "'#{substr}'"
          end.join(%q{,"'",})
          "concat(#{string})"
        else
          "'#{string}'"
        end
      end
      
      def wrap(path)
        if path.is_a?(self)
          path
        else
          new(path.to_s)
        end
      end

      def tempwrap(path)
        if path.is_a?(::XPath::Collection)
          path.map { |p| p.to_xpath }
        else
          wrap(path).paths
        end
      end

      def respond_to?(method)
        new.respond_to?(method)
      end

      def method_missing(*args)
        new.send(*args)
      end
    end

    attr_reader :paths

    def initialize(*paths)
      @paths = paths
    end

    def to_s
      @paths.join(' | ')
    end

    def append(path)
      XPath.new(*[@paths, XPath.wrap(path).paths].flatten)
    end

    def prepend(path)
      XPath.new(*[XPath.wrap(path).paths, @paths].flatten)
    end

    def from_css(css)
      XPath.new(*[@paths, Nokogiri::CSS.xpath_for(css).map { |selector| '.' + selector }].flatten)
    end
    alias_method :for_css, :from_css

    def field(locator, options={})
      if options[:with]
        fillable_field(locator, options)
      else
        xpath = fillable_field(locator)
        xpath = xpath.input_field(:file, locator, options)
        xpath = xpath.checkbox(locator, options)
        xpath = xpath.radio_button(locator, options)
        xpath.select(locator, options)
      end
    end

    def fillable_field(locator, options={})
      text_area(locator, options).text_field(locator, options)
    end

    def content(locator)
      append("./descendant-or-self::*[contains(normalize-space(.),#{s(locator)})]")
    end

    def table(locator, options={})
      conditions = ""
      if options[:rows]
        row_conditions = options[:rows].map do |row|
          row = row.map { |column| "*[self::td or self::th][text()=#{s(column)}]" }.join(sibling)
          "tr[./#{row}]"
        end.join(sibling)
        conditions << "[.//#{row_conditions}]"
      end
      append(".//table[@id=#{s(locator)} or contains(caption,#{s(locator)})]#{conditions}")
    end

    def fieldset(locator)
      append(".//fieldset[@id=#{s(locator)} or contains(legend,#{s(locator)})]")
    end

    def text_field(locator, options={})
      options = options.merge(:value => options[:with]) if options.has_key?(:with)
      add_field(locator, ".//input[not(@type) or (@type!='radio' and @type!='checkbox' and @type!='hidden')]", options)
    end

    def text_area(locator, options={})
      options = options.merge(:text => options[:with]) if options.has_key?(:with)
      add_field(locator, ".//textarea", options)
    end

    def select(locator, options={})
      add_field(locator, ".//select", options)
    end

    def checkbox(locator, options={})
      input_field(:checkbox, locator, options)
    end

    def radio_button(locator, options={})
      input_field(:radio, locator, options)
    end

    def file_field(locator, options={})
      input_field(:file, locator, options)
    end

    def option(name)
      append(".//option[normalize-space(text())=#{s(name)}]").append(".//option[contains(.,#{s(name)})]")
    end

  protected

    def input_field(type, locator, options={})
      options = options.merge(:value => options[:with]) if options.has_key?(:with)
      add_field(locator, ".//input[@type='#{type}']", options)
    end

    # place this between to nodes to indicate that they should be siblings
    def sibling
      '/following-sibling::*[1]/self::'
    end

    def add_field(locator, field, options={})
      postfix = extract_postfix(options)
      xpath = append("#{field}[@id=#{s(locator)}]#{postfix}")
      xpath = xpath.append("#{field}[@name=#{s(locator)}]#{postfix}")
      xpath = xpath.append("#{field}[@id=//label[contains(.,#{s(locator)})]/@for]#{postfix}")
      # FIXME: Label should not be scoped to node, temporary workaround!!!
      xpath = xpath.append(".//label[contains(.,#{s(locator)})]/#{field}#{postfix}")
      xpath.prepend("#{field}[@id=//label[text()=#{s(locator)}]/@for]#{postfix}")
    end

    def extract_postfix(options)
      options.inject("") do |postfix, (key, value)|
        case key
          when :value     then postfix += "[@value=#{s(value)}]"
          when :text      then postfix += "[text()=#{s(value)}]"
          when :checked   then postfix += "[@checked]"
          when :unchecked then postfix += "[not(@checked)]"
          when :options   then postfix += value.map { |o| "[.//option/text()=#{s(o)}]" }.join
          when :selected  then postfix += [value].flatten.map { |o| "[.//option[@selected]/text()=#{s(o)}]" }.join
        end
        postfix
      end
    end

    # Sanitize a String for putting it into an xpath query
    def s(string)
      XPath.escape(string)
    end

  end
end
