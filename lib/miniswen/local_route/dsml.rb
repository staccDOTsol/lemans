# frozen_string_literal: true

module Miniswen
  module LocalRoute
    # Textual DSML and the degraded invoke form the local V15 emits, turned
    # into bash tool calls. The schema is the bash tool miniswen sends: one
    # string `command`. Nothing else is filled in. A call limit keeps the
    # first calls and counts the rest; distinct arguments are not folded together.
    module Dsml
      TOKEN = "\uFF5CDSML\uFF5C"
      SCHEMA = { "bash" => { "command" => :string } }.freeze

      INVOKE_RE = %r{
        <(?:#{Regexp.escape(TOKEN)})?\s*invoke\s+name="(?<name>[^"]+)"\s*>
        (?<body>.*?)
        </(?:#{Regexp.escape(TOKEN)})?\s*invoke>
      }mx
      PARAM_RE = %r{
        <(?:#{Regexp.escape(TOKEN)})?\s*parameter\s+name="(?<name>[^"]+)"\s+string="(?<string>true|false)"\s*>
        (?<value>.*?)
        </(?:#{Regexp.escape(TOKEN)})?\s*parameter>
      }mx
      WRAPPER_RE = %r{</?(?:bash|tool_call|tool_calls|function_calls?|(?:#{Regexp.escape(TOKEN)})?\s*calls)>\s*}i
      THINK_CLOSE_RE = %r{</think>}i

      module_function

      def apply(content:, tool_calls:, limit: nil)
        calls = Array(tool_calls)
        return parse(content.to_s, limit:) if calls.empty?

        errors = []
        accepted = calls.filter_map do |call|
          verdict = accept(call[:name].to_s, call[:arguments])
          if verdict[:error]
            errors << verdict[:error]
            next
          end

          call.merge(arguments: verdict[:arguments])
        end
        kept = cap(accepted, limit)
        { content: content.to_s, calls: kept[:calls], errors:, raw: content.to_s, omitted: kept[:omitted], parse_path: "openai" }
      end

      def parse(text, limit: nil)
        errors = []
        accepted = []
        pieces = []
        cursor = 0
        while (match = INVOKE_RE.match(text, cursor))
          pieces << text[cursor...match.begin(0)]
          cursor = match.end(0)
          verdict = invoke(match[:name].strip, match[:body])
          verdict[:error] ? errors << verdict[:error] : accepted << verdict[:call]
        end
        pieces << text[cursor..]
        kept = cap(accepted, limit)
        {
          content: clean(pieces.join),
          calls: number(kept[:calls]),
          errors:,
          raw: text,
          omitted: kept[:omitted],
          parse_path: path_for(text, accepted, errors)
        }
      end

      def invoke(name, body)
        args = {}
        cursor = 0
        while (match = PARAM_RE.match(body, cursor))
          cursor = match.end(0)
          pname = match[:name]
          return { error: "duplicate parameter #{pname.inspect} in invoke #{name.inspect}" } if args.key?(pname)

          flag = match[:string]
          return { error: "parameter #{pname.inspect} string flag #{flag.inspect} is not true or false" } unless flag == "true" || flag == "false"

          spec = SCHEMA[name]
          return { error: "invoke name #{name.inspect} not in allowed tools #{SCHEMA.keys.inspect}" } unless spec
          return { error: "parameter #{pname.inspect} is not in the #{name} schema" } unless spec.key?(pname)
          return { error: "parameter #{pname.inspect} must be a string (string=\"true\")" } unless flag == "true"

          args[pname] = match[:value]
        end
        return { error: "invoke name #{name.inspect} not in allowed tools #{SCHEMA.keys.inspect}" } unless SCHEMA.key?(name)

        residue = body.gsub(PARAM_RE, "").strip
        return { error: "invoke #{name.inspect} has non-parameter body residue: #{residue[0, 80].inspect}" } unless residue.empty?
        return { error: "invoke #{name.inspect} produced empty arguments" } if args.empty?

        missing = SCHEMA[name].keys - args.keys
        return { error: "invoke #{name.inspect} missing #{missing.inspect}" } if missing.any?

        { call: { name:, arguments: args } }
      end

      def accept(name, arguments)
        spec = SCHEMA[name]
        return { error: "invoke name #{name.inspect} not in allowed tools #{SCHEMA.keys.inspect}" } unless spec
        return { error: "invoke #{name.inspect} arguments are not an object" } unless arguments.is_a?(Hash)

        arguments.each_key do |key|
          return { error: "parameter #{key.inspect} is not in the #{name} schema" } unless spec.key?(key.to_s)
        end
        spec.each_key do |key|
          return { error: "invoke #{name.inspect} missing #{[ key ].inspect}" } unless arguments.key?(key) || arguments.key?(key.to_sym)
        end
        command = arguments.key?("command") ? arguments["command"] : arguments[:command]
        return { error: "parameter \"command\" must be a string (string=\"true\")" } unless command.is_a?(String)

        { arguments: { "command" => command } }
      end

      def cap(calls, limit)
        return { calls:, omitted: 0 } if limit.nil?

        { calls: calls.first(limit), omitted: calls.size - calls.first(limit).size }
      end

      def number(calls)
        calls.each_with_index.map { |call, index| call.merge(id: "call_dsml_#{index + 1}") }
      end

      def clean(text)
        text.gsub(WRAPPER_RE, "").gsub(THINK_CLOSE_RE, "").gsub(/\n{3,}/, "\n\n").strip
      end

      def path_for(text, accepted, errors)
        return "none" if accepted.empty? && errors.empty?
        return "degraded_invoke_failed" if accepted.empty?

        text.include?(TOKEN) ? "dsml" : "degraded_invoke"
      end
    end
  end
end
