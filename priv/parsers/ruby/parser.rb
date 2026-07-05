#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'parser/current'
require 'json'

module Metastatic
  # Ruby AST parser that converts Ruby source code to JSON-serializable format
  class RubyParser
    # Parse Ruby source code and return JSON-serializable AST
    #
    # @param source [String] Ruby source code
    # @return [Hash] Serialized AST or error information
    def self.parse(source)
      buffer = Parser::Source::Buffer.new('(string)', source: source)
      parser = Parser::CurrentRuby.new
      ast = parser.parse(buffer)
      
      {
        status: 'ok',
        ast: serialize_node(ast)
      }
    rescue Parser::SyntaxError => e
      {
        status: 'error',
        error: e.message,
        line: e.diagnostic.location.line,
        column: e.diagnostic.location.column
      }
    rescue StandardError => e
      {
        status: 'error',
        error: "#{e.class}: #{e.message}",
        backtrace: e.backtrace.first(5)
      }
    end

    # Serialize a Parser::AST::Node to a JSON-friendly structure
    #
    # @param node [Parser::AST::Node, nil] AST node to serialize
    # @return [Hash, nil] Serialized node structure
    def self.serialize_node(node)
      return nil if node.nil?

      # Handle non-node values (literals)
      unless node.is_a?(Parser::AST::Node)
        return node
      end

      {
        type: node.type.to_s,
        children: node.children.map { |child| serialize_node(child) },
        location: serialize_location(node.location)
      }
    end

    # Serialize location information
    #
    # @param loc [Parser::Source::Map] Location map
    # @return [Hash] Serialized location info
    def self.serialize_location(loc)
      return nil unless loc && loc.expression

      {
        begin_pos: loc.expression.begin_pos,
        end_pos: loc.expression.end_pos,
        begin_line: loc.expression.line,
        begin_column: loc.expression.column
      }
    rescue StandardError
      nil
    end
  end
end

# CLI interface: read from STDIN, write JSON to STDOUT
if __FILE__ == $PROGRAM_NAME
  source = $stdin.read
  result = Metastatic::RubyParser.parse(source)
  puts JSON.generate(result)
end
