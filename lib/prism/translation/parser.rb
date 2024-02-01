# frozen_string_literal: true

require "parser"

module Prism
  module Translation
    # This class is the entry-point for converting a prism syntax tree into the
    # whitequark/parser gem's syntax tree. It inherits from the base parser for
    # the parser gem, and overrides the parse* methods to parse with prism and
    # then translate.
    class Parser < ::Parser::Base
      # The parser gem has a list of diagnostics with a hard-coded set of error
      # messages. We create our own diagnostic class in order to set our own
      # error messages.
      class Diagnostic < ::Parser::Diagnostic
        # The message generated by prism.
        attr_reader :message

        # Initialize a new diagnostic with the given message and location.
        def initialize(message, location)
          @message = message
          super(:error, :prism_error, {}, location, [])
        end
      end

      Racc_debug_parser = false # :nodoc:

      def version # :nodoc:
        33
      end

      # The default encoding for Ruby files is UTF-8.
      def default_encoding
        Encoding::UTF_8
      end

      def yyerror # :nodoc:
      end

      # Parses a source buffer and returns the AST.
      def parse(source_buffer)
        @source_buffer = source_buffer
        source = source_buffer.source

        result = unwrap(Prism.parse(source, filepath: source_buffer.name))

        build_ast(result.value, build_offset_cache(source))
      ensure
        @source_buffer = nil
      end

      # Parses a source buffer and returns the AST and the source code comments.
      def parse_with_comments(source_buffer)
        @source_buffer = source_buffer
        source = source_buffer.source

        offset_cache = build_offset_cache(source)
        result = unwrap(Prism.parse(source, filepath: source_buffer.name))

        [
          build_ast(result.value, offset_cache),
          build_comments(result.comments, offset_cache)
        ]
      ensure
        @source_buffer = nil
      end

      # Parses a source buffer and returns the AST, the source code comments,
      # and the tokens emitted by the lexer.
      def tokenize(source_buffer, _recover = false)
        @source_buffer = source_buffer
        source = source_buffer.source

        offset_cache = build_offset_cache(source)
        result = unwrap(Prism.parse_lex(source, filepath: source_buffer.name))

        program, tokens = result.value

        [
          build_ast(program, offset_cache),
          build_comments(result.comments, offset_cache),
          build_tokens(tokens, offset_cache)
        ]
      ensure
        @source_buffer = nil
      end

      # Since prism resolves num params for us, we don't need to support this
      # kind of logic here.
      def try_declare_numparam(node)
        node.children[0].match?(/\A_[1-9]\z/)
      end

      private

      # This is a hook to allow consumers to disable some errors if they don't
      # want them to block creating the syntax tree.
      def valid_error?(error)
        true
      end

      # If there was a error generated during the parse, then raise an
      # appropriate syntax error. Otherwise return the result.
      def unwrap(result)
        error = result.errors.find { |error| valid_error?(error) }
        return result if error.nil?

        offset_cache = build_offset_cache(source_buffer.source)
        diagnostic = Diagnostic.new(error.message, build_range(error.location, offset_cache))

        raise ::Parser::SyntaxError, diagnostic
      end

      # Prism deals with offsets in bytes, while the parser gem deals with
      # offsets in characters. We need to handle this conversion in order to
      # build the parser gem AST.
      #
      # If the bytesize of the source is the same as the length, then we can
      # just use the offset directly. Otherwise, we build a hash that functions
      # as a cache for the conversion.
      #
      # This is a good opportunity for some optimizations. If the source file
      # has any multi-byte characters, this can tank the performance of the
      # translator. We could make this significantly faster by using a
      # different data structure for the cache.
      def build_offset_cache(source)
        if source.bytesize == source.length
          -> (offset) { offset }
        else
          Hash.new do |hash, offset|
            hash[offset] = source.byteslice(0, offset).length
          end
        end
      end

      # Build the parser gem AST from the prism AST.
      def build_ast(program, offset_cache)
        program.accept(Compiler.new(self, offset_cache))
      end

      # Build the parser gem comments from the prism comments.
      def build_comments(comments, offset_cache)
        comments.map do |comment|
          ::Parser::Source::Comment.new(build_range(comment.location, offset_cache))
        end
      end

      # Build the parser gem tokens from the prism tokens.
      def build_tokens(tokens, offset_cache)
        Lexer.new(source_buffer, tokens.map(&:first), offset_cache).to_a
      end

      # Build a range from a prism location.
      def build_range(location, offset_cache)
        ::Parser::Source::Range.new(
          source_buffer,
          offset_cache[location.start_offset],
          offset_cache[location.end_offset]
        )
      end

      require_relative "parser/compiler"
      require_relative "parser/lexer"

      private_constant :Compiler
      private_constant :Lexer
    end
  end
end
