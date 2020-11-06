# frozen_string_literal: true

require 'pronto'
require 'ffi/aspell'

module Pronto
  class Spell < Runner
    CONFIG_FILE = '.pronto_spell.yml'

    def whitelist
      @whitelist ||= (spelling_config['whitelist'] || []).map { |matcher| regexpify(matcher) }
    end

    def files_to_lint
      @files_to_lint ||= regexpify(spelling_config['files_to_lint'] || '\\.rb$')
    end

    def ignored_words
      @ignored_words ||= begin
        Set.new(spelling_config['ignored_words'].to_a.map(&:downcase))
      end
    end

    def keywords
      @keywords ||= begin
        Set.new(spelling_config['only_lines_matching'].to_a.map(&:downcase))
      end
    end

    def run
      return [] if !@patches || @patches.count.zero?

      @all_symbols = Symbol.all_symbols

      @patches
        .select { |patch| patch.additions.positive? && lintable_file?(patch.new_file_full_path) }
        .map { |patch| inspect(patch) }
        .flatten.compact
    end

    private

    def inspect(patch)
      patch.added_lines.map do |line|
        if keywords.any? && !keywords_regexp.match(line.content)
          next
        end

        extract_words(line.content)
          .select { |word| misspelled?(word) }
          .map { |word| new_message(word, line) }
      end
    end

    def new_message(word, line)
      path = line.patch.delta.new_file[:path]
      level = :info

      suggestions = speller.suggestions(word)

      msg = %("#{word}" might not be spelled correctly.)
      if suggestions.any?
        suggestions_text = suggestions[0..max_suggestions_number - 1].join(', ')
        msg += " Spelling suggestions: #{suggestions_text}"
      end

      Message.new(path, line, level, msg, nil, self.class)
    end

    def speller
      @speller ||= FFI::Aspell::Speller.new(
        language, 'sug-mode': suggestion_mode
      )
    end

    def spelling_config
      @spelling_config ||= begin
        config_path = File.join(repo_path, CONFIG_FILE)
        File.exist?(config_path) ? YAML.load_file(config_path) : {}
      end
    end

    def keywords_regexp
      @keywords_regexp ||= %r{#{keywords.to_a.join('|')}}
    end

    def language
      spelling_config['language'] || 'en_US'
    end

    def suggestion_mode
      spelling_config['suggestion_mode'] || 'fast'
    end

    def min_word_length
      spelling_config['min_word_length'] || 5
    end

    def max_word_length
      spelling_config['max_word_length'] || Float::INFINITY
    end

    def max_suggestions_number
      spelling_config['max_suggestions_number'] || 3
    end

    def misspelled?(word)
      lintable_word?(word) && !speller.correct?(word) && !speller.correct?(singularize(word))
    end

    def lintable_word?(word)
      (min_word_length..max_word_length).cover?(word.length) &&
        !ignored_words.include?(word.downcase) &&
        !symbol_defined?(word) && !whitelist.any? { |regexp| regexp =~ word }
    end

    def lintable_file?(path)
      files_to_lint =~ path.to_s
    end

    def singularize(word)
      word.sub(/(e?s|\d+)\z/, '')
    end

    def regexpify(matcher)
      Regexp.new(matcher, Regexp::IGNORECASE)
    end

    def symbol_defined?(symbol)
      @all_symbols.include?(symbol.to_sym)
    end

    def extract_words(content)
      content.scan(/[0-9a-zA-Z]+/).grep(/\A[a-zA-Z]+\z/).flat_map do |word|
        # Recognize acronyms embedded in the CamelCase:
        # for example, split "MyHTMLTricks" into "My HTML Tricks" instead of "My H T M L Tricks".
        word.
          gsub(/([[:lower:]\\d])([[:upper:]])/, '\1 \2').
          gsub(/([^-\\d])(\\d[-\\d]*( |$))/,'\1 \2').
          gsub(/([[:upper:]])([[:upper:]][[:lower:]\\d])/, '\1 \2').split
      end.uniq
    end
  end
end
