require 'parslet'

module Rundoc
  class PegParser < Parslet::Parser
    rule(:spaces)  { match('\s').repeat(1) }
    rule(:spaces?) { spaces.maybe }
    rule(:comma)   { spaces? >> str(',') >> spaces? }
    rule(:digit)   { match('[0-9]') }
    rule(:lparen)  { str('(') >> spaces? }
    rule(:rparen)  { str(')') >> spaces? }
    rule(:newline)     { str("\r").maybe >> str("\n") }

    rule(:singlequote_string) {
      str("'") >> (
        str("'").absnt? >> any
      ).repeat.as(:string) >>
      str("'") >> spaces?
    }
    rule(:doublequote_string) {
      str('"') >> (
        str('"').absnt? >> any
      ).repeat.as(:string) >>
      str('"') >> spaces?
    }
    rule(:string) { doublequote_string | singlequote_string }

    rule(:number) {
      (
        str('-').maybe >> (
          str('0') | (match('[1-9]') >> digit.repeat)
        ) >> (
          str('.') >> digit.repeat(1)
        ).maybe >> (
          match('[eE]') >> (str('+') | str('-')).maybe >> digit.repeat(1)
        ).maybe
      ).as(:number)
    }

    rule(:value) {
      string |
      number |
      str('true').as(:true) |
      str('false').as(:false) |
      str('nil').as(:nil)
    }

    rule(:key) {
      spaces? >> (
        str(':').absent? >> match('\s').absent? >> any
      ).repeat.as(:key) >> str(':') >> spaces?
    }

    rule(:key_value) {
      (
        key >> value.as(:val)
      ).as(:key_value) >> spaces?
    }

    rule(:named_args) {
      spaces? >> (
        key_value >>  (comma >> key_value).repeat
      ).as(:named_args) >>
      spaces?
    }

    rule(:unquoted_string) {
      (any.repeat(1)).as(:string) #>> newline
    }

    rule(:args) {
      named_args | string | unquoted_string
    }

    rule(:funcall) {
      spaces? >> match('[^ \(\)]').repeat(1).as(:funcall)
    }

    rule(:parens_method) {
      funcall >> lparen >>
      args.as(:args) >>
      rparen
    }

    rule(:seattle_method) {
      funcall >> spaces >>
      args.as(:args)
    }

    rule(:method_call) {
      (parens_method | seattle_method).as(:method_call)
    }

    # >>
    # >-
    # ->
    # --
    rule(:visability) {
      (
        match('>|-').as(:vis_command) >> match('>|-').as(:vis_result)
      ).as(:visability)
    }

    # :::
    rule(:start_command) {
      match(/\A:/) >> str('::')
    }

    # :::>> $ cat foo.rb
    rule(:command) {
      (
        start_command >>
        visability.as(:cmd_visability) >> spaces? >>
        method_call.as(:cmd_method_call) >> newline.maybe
      ).as(:command)
    }

    # :::>> file.write hello.txt
    # world
    rule(:command_with_stdin) {
      command >>
        (
          start_command.absent? >>
          code_fence.absent? >>
          any
        ).repeat(1).as(:stdin) |
        command
    }


    # :::>> file.write hello.txt
    # world
    # :::>> file.write foo.txt
    # bar
    rule(:multiple_commands) {
      (command_with_stdin | command).repeat
    }

    rule(:code_fence) {
      match(/\A`/) >> str("``")
    }

    rule(:fenced_commands) {
      code_fence >>
        match('\S').repeat >>
        newline >>
      multiple_commands >>
      code_fence >> newline
    }

    rule(:raw_code) {
      (command.absent? >> any).repeat(1).as(:raw_code) >>
      multiple_commands.maybe
    }

    rule(:code_block) {
      raw_code | multiple_commands
    }
  end
end


module Rundoc
  class PegTransformer < Parslet::Transform
    rule(nill:   simple(:nu)) { nil }
    rule(true:   simple(:tr)) { true }
    rule(false:  simple(:fa)) { false }
    rule(string: simple(:st)) { st.to_s }

    rule(:number => simple(:nb)) {
      nb.match(/[eE\.]/) ? Float(nb) : Integer(nb)
    }

    rule(:named_args => subtree(:na)) {
      (na.is_a?(Array) ? na : [ na ]).each_with_object({}) { |element, hash|
        key = element[:key_value][:key].to_sym
        val = element[:key_value][:val]
        hash[key] = val
      }
    }

    rule(method_call: subtree(:mc)) {
      keyword = mc[:funcall].to_sym
      args    = mc[:args]
      Rundoc.code_command_from_keyword(keyword, args)
    }

    class Visability
      attr_reader :command, :result
      alias :command? :command
      alias :result? :result
      def initialize(command:, result:)
        @command = command
        @result  = result
      end
    end

    rule(:visability => {
            vis_command: simple(:command),
            vis_result:  simple(:result)
        }) {
      Visability.new(
        command: command.to_s == '>'.freeze,
        result:  result.to_s  == '>'.freeze
      )
    }

    rule(
      cmd_visability: simple(:cmd_vis),      # Visibility#new
      cmd_method_call: simple(:code_command) # Rundoc::CodeCommand#new
        ) {
      code_command.render_command = cmd_vis.command?
      code_command.render_result  = cmd_vis.result?
      code_command
    }

    rule(command: simple(:code_command)) {
      code_command
    }

    rule(command: simple(:code_command), stdin: simple(:str)) {
      code_command << str
      code_command
    }

    # The lines before a CodeCommand are rendered
    # without running any code
    rule(raw_code: simple(:raw_code)) {
      CodeCommand::Raw.new(raw_code)
    }

    # Sometimes
    rule(raw_code: sequence(:raw_code)) {
      hidden = raw_code.nil? || raw_code.empty?
      CodeCommand::Raw.new(raw_code, visible: !hidden)
    }
  end
end
