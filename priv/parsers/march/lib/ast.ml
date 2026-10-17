(* Pure OCaml March Lexer, Parser & AST JSON Exporter *)

type json =
  | JNull
  | JBool of bool
  | JInt of int
  | JFloat of float
  | JString of string
  | JList of json list
  | JAssoc of (string * json) list

let escape_str s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter (function
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.add_char buf '"';
  Buffer.contents buf

let rec json_to_string = function
  | JNull -> "null"
  | JBool b -> if b then "true" else "false"
  | JInt i -> string_of_int i
  | JFloat f ->
      let s = string_of_float f in
      if String.get s (String.length s - 1) = '.' then s ^ "0" else s
  | JString s -> escape_str s
  | JList l -> "[" ^ String.concat "," (List.map json_to_string l) ^ "]"
  | JAssoc a ->
      "{" ^ String.concat "," (List.map (fun (k, v) -> escape_str k ^ ":" ^ json_to_string v) a) ^ "}"

type token = {
  v : string;
  line : int;
  col : int;
}

let tokenize (source : string) : token list =
  let tokens = ref [] in
  let lines = String.split_on_char '\n' source in
  let is_space c = c = ' ' || c = '\t' || c = '\r' in
  let is_ident_start c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_' in
  let is_ident_char c = is_ident_start c || (c >= '0' && c <= '9') in
  let is_digit c = c >= '0' && c <= '9' in

  List.iteri (fun line_idx line ->
    let line_num = line_idx + 1 in
    let line_code = match String.split_on_char '#' line with
      | head :: _ -> head
      | [] -> "" in
    let len = String.length line_code in
    let i = ref 0 in

    while !i < len do
      let c = line_code.[!i] in
      if is_space c then
        incr i
      else if c = '"' then (
        let start_col = !i + 1 in
        incr i;
        let buf = Buffer.create 16 in
        let escaped = ref false in
        let done_str = ref false in
        while !i < len && not !done_str do
          let cc = line_code.[!i] in
          if !escaped then (
            Buffer.add_char buf cc;
            escaped := false;
            incr i
          ) else if cc = '\\' then (
            escaped := true;
            incr i
          ) else if cc = '"' then (
            done_str := true;
            incr i
          ) else (
            Buffer.add_char buf cc;
            incr i
          )
        done;
        let str_val = "\"" ^ Buffer.contents buf ^ "\"" in
        tokens := { v = str_val; line = line_num; col = start_col } :: !tokens
      ) else if is_digit c then (
        let start_col = !i + 1 in
        let start_i = !i in
        while !i < len && (is_digit line_code.[!i] || line_code.[!i] = '.') do
          incr i
        done;
        let num_str = String.sub line_code start_i (!i - start_i) in
        tokens := { v = num_str; line = line_num; col = start_col } :: !tokens
      ) else if is_ident_start c then (
        let start_col = !i + 1 in
        let start_i = !i in
        while !i < len && is_ident_char line_code.[!i] do
          incr i
        done;
        let id_str = String.sub line_code start_i (!i - start_i) in
        tokens := { v = id_str; line = line_num; col = start_col } :: !tokens
      ) else (
        let start_col = !i + 1 in
        let two = if !i + 1 < len then String.sub line_code !i 2 else "" in
        if two = "++" || two = "|>" || two = "->" || two = "=>" || two = "==" || two = "!=" || two = "<=" || two = ">=" || two = "&&" || two = "||" then (
          tokens := { v = two; line = line_num; col = start_col } :: !tokens;
          i := !i + 2
        ) else (
          let single = String.make 1 c in
          tokens := { v = single; line = line_num; col = start_col } :: !tokens;
          incr i
        )
      )
    done
  ) lines;
  List.rev !tokens

type march_parser = {
  toks : token array;
  mutable pos : int;
}

let peek p =
  if p.pos < Array.length p.toks then Some p.toks.(p.pos) else None

let match_tok p expected =
  match peek p with
  | Some t when t.v = expected -> p.pos <- p.pos + 1; Some t
  | _ -> None

let expect p expected =
  match match_tok p expected with
  | Some t -> t
  | None ->
      let got = match peek p with Some t -> "'" ^ t.v ^ "'" | None -> "EOF" in
      failwith ("Expected '" ^ expected ^ "', got " ^ got)

let parse_program_json (source : string) : json =
  let toks_list = tokenize source in
  let p = { toks = Array.of_list toks_list; pos = 0 } in

  let rec parse_toplevel () =
    match peek p with
    | Some { v = "mod"; _ } -> parse_module ()
    | Some { v = "actor"; _ } -> parse_actor ()
    | Some { v = "fn"; _ } -> parse_function "public"
    | Some { v = "pfn"; _ } -> parse_function "private"
    | Some { v = "needs"; _ } -> parse_needs ()
    | Some { v = "use"; _ } -> parse_use ()
    | Some { v = "type"; _ } -> parse_type ()
    | _ -> parse_statement ()

  and parse_module () =
    let mod_t = expect p "mod" in
    let name_t = match peek p with Some t -> p.pos <- p.pos + 1; t | None -> failwith "Expected module name" in
    ignore (expect p "do");
    let body = ref [] in
    while peek p <> None && (match peek p with Some { v = "end"; _ } -> false | _ -> true) do
      body := parse_toplevel () :: !body
    done;
    ignore (expect p "end");
    JAssoc [
      ("_type", JString "Module");
      ("name", JString name_t.v);
      ("body", JList (List.rev !body));
      ("lineno", JInt mod_t.line);
      ("col_offset", JInt mod_t.col)
    ]

  and parse_actor () =
    let act_t = expect p "actor" in
    let name_t = match peek p with Some t -> p.pos <- p.pos + 1; t | None -> failwith "Expected actor name" in
    ignore (expect p "do");
    let state_json = ref JNull in
    let init_json = ref JNull in
    let handlers = ref [] in
    while peek p <> None && (match peek p with Some { v = "end"; _ } -> false | _ -> true) do
      match peek p with
      | Some { v = "state"; _ } ->
          ignore (expect p "state");
          state_json := parse_record ()
      | Some { v = "init"; _ } ->
          ignore (expect p "init");
          init_json := parse_expression ()
      | Some { v = "on"; _ } ->
          handlers := parse_on_handler () :: !handlers
      | _ ->
          handlers := parse_toplevel () :: !handlers
    done;
    ignore (expect p "end");
    JAssoc [
      ("_type", JString "Actor");
      ("name", JString name_t.v);
      ("state", !state_json);
      ("init", !init_json);
      ("handlers", JList (List.rev !handlers));
      ("lineno", JInt act_t.line);
      ("col_offset", JInt act_t.col)
    ]

  and parse_needs () =
    let n_tok = match peek p with Some t -> p.pos <- p.pos + 1; t | None -> failwith "Expected needs" in
    let cap_buf = ref "" in
    while peek p <> None && (match peek p with Some { line; _ } -> line = n_tok.line | None -> false) do
      match peek p with
      | Some t -> p.pos <- p.pos + 1; cap_buf := if !cap_buf = "" then t.v else !cap_buf ^ t.v
      | None -> ()
    done;
    JAssoc [
      ("_type", JString "Needs");
      ("capability", JString !cap_buf);
      ("lineno", JInt n_tok.line);
      ("col_offset", JInt n_tok.col)
    ]

  and parse_use () =
    let u_tok = match peek p with Some t -> p.pos <- p.pos + 1; t | None -> failwith "Expected use" in
    let mod_buf = ref "" in
    while peek p <> None && (match peek p with Some { line; _ } -> line = u_tok.line | None -> false) do
      match peek p with
      | Some t -> p.pos <- p.pos + 1; mod_buf := if !mod_buf = "" then t.v else !mod_buf ^ t.v
      | None -> ()
    done;
    JAssoc [
      ("_type", JString "Use");
      ("module", JString !mod_buf);
      ("lineno", JInt u_tok.line);
      ("col_offset", JInt u_tok.col)
    ]

  and parse_on_handler () =
    let on_t = expect p "on" in
    let msg_name = match peek p with Some t -> p.pos <- p.pos + 1; t.v | None -> failwith "Expected message name" in
    let params = ref [] in
    if match_tok p "(" <> None then (
      while peek p <> None && (match peek p with Some { v = ")"; _ } -> false | _ -> true) do
        let pname = match peek p with Some t -> p.pos <- p.pos + 1; t.v | None -> failwith "Expected param name" in
        let ptype = ref JNull in
        if match_tok p ":" <> None then (
          match peek p with
          | Some t -> p.pos <- p.pos + 1; ptype := JString t.v
          | None -> ()
        );
        let p_json = JAssoc [("_type", JString "Param"); ("name", JString pname); ("type", !ptype)] in
        params := p_json :: !params;
        if match_tok p "," = None then ()
      done;
      ignore (expect p ")")
    );
    ignore (expect p "do");
    let body = ref [] in
    while peek p <> None && (match peek p with Some { v = "end"; _ } -> false | _ -> true) do
      body := parse_statement () :: !body
    done;
    ignore (expect p "end");
    JAssoc [
      ("_type", JString "OnHandler");
      ("message", JString msg_name);
      ("params", JList (List.rev !params));
      ("body", JList (List.rev !body));
      ("lineno", JInt on_t.line);
      ("col_offset", JInt on_t.col)
    ]

  and parse_function (vis : string) =
    let fn_t = match peek p with Some t -> p.pos <- p.pos + 1; t | None -> failwith "Expected fn/pfn" in
    let name_t = match peek p with Some t -> p.pos <- p.pos + 1; t | None -> failwith "Expected fn name" in
    let params = ref [] in
    if match_tok p "(" <> None then (
      while peek p <> None && (match peek p with Some { v = ")"; _ } -> false | _ -> true) do
        let pname = match peek p with Some t -> p.pos <- p.pos + 1; t.v | None -> failwith "Expected param name" in
        let ptype = ref JNull in
        if match_tok p ":" <> None then (
          match peek p with
          | Some t -> p.pos <- p.pos + 1; ptype := JString t.v
          | None -> ()
        );
        let p_json = JAssoc [("_type", JString "Param"); ("name", JString pname); ("type", !ptype)] in
        params := p_json :: !params;
        if match_tok p "," = None then ()
      done;
      ignore (expect p ")")
    );
    let ret_type = ref JNull in
    if match_tok p ":" <> None || match_tok p "->" <> None then (
      match peek p with
      | Some t -> p.pos <- p.pos + 1; ret_type := JString t.v
      | None -> ()
    );
    ignore (expect p "do");
    let body = ref [] in
    while peek p <> None && (match peek p with Some { v = "end"; _ } -> false | _ -> true) do
      body := parse_statement () :: !body
    done;
    ignore (expect p "end");
    JAssoc [
      ("_type", JString "FunctionDef");
      ("name", JString name_t.v);
      ("visibility", JString vis);
      ("params", JList (List.rev !params));
      ("return_type", !ret_type);
      ("body", JList (List.rev !body));
      ("lineno", JInt fn_t.line);
      ("col_offset", JInt fn_t.col)
    ]

  and parse_type () =
    let t_tok = expect p "type" in
    let name_t = match peek p with Some t -> p.pos <- p.pos + 1; t | None -> failwith "Expected type name" in
    ignore (expect p "=");
    let variants = ref [] in
    while peek p <> None && (match peek p with Some t -> t.line = t_tok.line | None -> false) do
      ignore (match_tok p "|");
      let vname = match peek p with Some t -> p.pos <- p.pos + 1; t.v | None -> failwith "Expected variant name" in
      let args = ref [] in
      if match_tok p "(" <> None then (
        while peek p <> None && (match peek p with Some { v = ")"; _ } -> false | _ -> true) do
          match peek p with
          | Some t -> p.pos <- p.pos + 1; args := JString t.v :: !args
          | None -> ();
          if match_tok p "," = None then ()
        done;
        ignore (expect p ")")
      );
      variants := JAssoc [("_type", JString "Variant"); ("name", JString vname); ("args", JList (List.rev !args))] :: !variants;
      if match peek p with Some { v = "|"; _ } -> false | _ -> true then ()
    done;
    JAssoc [
      ("_type", JString "TypeDecl");
      ("name", JString name_t.v);
      ("variants", JList (List.rev !variants));
      ("lineno", JInt t_tok.line);
      ("col_offset", JInt t_tok.col)
    ]

  and parse_statement () =
    match peek p with
    | Some { v = "let"; _ } ->
        let let_t = expect p "let" in
        let var_t = match peek p with Some t -> p.pos <- p.pos + 1; t | None -> failwith "Expected var name" in
        ignore (expect p "=");
        let val_expr = parse_expression () in
        JAssoc [
          ("_type", JString "Let");
          ("name", JString var_t.v);
          ("value", val_expr);
          ("lineno", JInt let_t.line);
          ("col_offset", JInt let_t.col)
        ]
    | Some { v = "match"; _ } -> parse_match ()
    | _ -> parse_expression ()

  and parse_match () =
    let m_tok = expect p "match" in
    let expr = parse_expression () in
    ignore (expect p "do");
    let arms = ref [] in
    while peek p <> None && (match peek p with Some { v = "end"; _ } -> false | _ -> true) do
      let pat = parse_pattern () in
      if match_tok p "->" = None && match_tok p "=>" = None then
        ignore (expect p "->");
      let body = parse_expression () in
      arms := JAssoc [("_type", JString "MatchArm"); ("pattern", pat); ("body", body)] :: !arms
    done;
    ignore (expect p "end");
    JAssoc [
      ("_type", JString "Match");
      ("expr", expr);
      ("arms", JList (List.rev !arms));
      ("lineno", JInt m_tok.line);
      ("col_offset", JInt m_tok.col)
    ]

  and parse_pattern () =
    match peek p with
    | Some { v; _ } when String.length v > 0 && v.[0] >= 'A' && v.[0] <= 'Z' ->
        p.pos <- p.pos + 1;
        let args = ref [] in
        if match_tok p "(" <> None then (
          while peek p <> None && (match peek p with Some { v = ")"; _ } -> false | _ -> true) do
            args := parse_pattern () :: !args;
            if match_tok p "," = None then ()
          done;
          ignore (expect p ")")
        );
        JAssoc [("_type", JString "ConstructorPattern"); ("name", JString v); ("args", JList (List.rev !args))]
    | Some { v; _ } ->
        p.pos <- p.pos + 1;
        JAssoc [("_type", JString "VariablePattern"); ("name", JString v)]
    | None -> failwith "Unexpected EOF in pattern"

  and parse_record () =
    ignore (expect p "{");
    let fields = ref [] in
    let is_update = ref false in
    let target = ref "" in
    if peek p <> None && (let p1 = p.pos in if p1 + 1 < Array.length p.toks then p.toks.(p1 + 1).v = "with" else false) then (
      match peek p with
      | Some t -> p.pos <- p.pos + 1; target := t.v; ignore (expect p "with"); is_update := true
      | None -> ()
    );
    while peek p <> None && (match peek p with Some { v = "}"; _ } -> false | _ -> true) do
      let fname = match peek p with Some t -> p.pos <- p.pos + 1; t.v | None -> failwith "Expected field name" in
      ignore (expect p ":");
      let fval = parse_expression () in
      fields := JAssoc [("field", JString fname); ("value", fval)] :: !fields;
      if match_tok p "," = None then ()
    done;
    ignore (expect p "}");
    if !is_update then
      JAssoc [("_type", JString "RecordUpdate"); ("target", JString !target); ("fields", JList (List.rev !fields))]
    else
      JAssoc [("_type", JString "Record"); ("fields", JList (List.rev !fields))]

  and parse_expression () =
    let left = ref (parse_primary ()) in
    let loop = ref true in
    while !loop do
      match peek p with
      | Some { v = op; line; col } when op = "++" || op = "+" || op = "-" || op = "*" || op = "/" || op = "==" || op = "!=" || op = "<" || op = ">" || op = "<=" || op = ">=" || op = "&&" || op = "||" || op = "|>" ->
          p.pos <- p.pos + 1;
          let right = parse_primary () in
          left := JAssoc [
            ("_type", JString "BinOp");
            ("op", JString op);
            ("left", !left);
            ("right", right);
            ("lineno", JInt line);
            ("col_offset", JInt col)
          ]
      | _ -> loop := false
    done;
    !left

  and parse_primary () =
    match peek p with
    | Some { v = "{"; _ } -> parse_record ()
    | Some { v = "("; _ } ->
        ignore (expect p "(");
        let e = parse_expression () in
        ignore (expect p ")");
        e
    | Some { v; line; col } ->
        p.pos <- p.pos + 1;
        if String.length v > 0 && (v.[0] >= '0' && v.[0] <= '9') then
          if String.contains v '.' then
            JAssoc [("_type", JString "Constant"); ("value", JFloat (float_of_string v)); ("subtype", JString "float"); ("lineno", JInt line); ("col_offset", JInt col)]
          else
            JAssoc [("_type", JString "Constant"); ("value", JInt (int_of_string v)); ("subtype", JString "integer"); ("lineno", JInt line); ("col_offset", JInt col)]
        else if String.length v > 0 && v.[0] = '"' then
          let unquoted = String.sub v 1 (String.length v - 2) in
          JAssoc [("_type", JString "Constant"); ("value", JString unquoted); ("subtype", JString "string"); ("lineno", JInt line); ("col_offset", JInt col)]
        else if v = "true" || v = "false" then
          JAssoc [("_type", JString "Constant"); ("value", JBool (v = "true")); ("subtype", JString "boolean"); ("lineno", JInt line); ("col_offset", JInt col)]
        else if match_tok p "." <> None then (
          let attr = match peek p with Some t -> p.pos <- p.pos + 1; t.v | None -> failwith "Expected attr name" in
          if match_tok p "(" <> None then (
            let args = ref [] in
            while peek p <> None && (match peek p with Some { v = ")"; _ } -> false | _ -> true) do
              args := parse_expression () :: !args;
              if match_tok p "," = None then ()
            done;
            ignore (expect p ")");
            JAssoc [("_type", JString "Call"); ("func", JString (v ^ "." ^ attr)); ("args", JList (List.rev !args)); ("lineno", JInt line); ("col_offset", JInt col)]
          ) else
            JAssoc [("_type", JString "AttributeAccess"); ("receiver", JString v); ("attribute", JString attr); ("lineno", JInt line); ("col_offset", JInt col)]
        ) else if match_tok p "(" <> None then (
          let args = ref [] in
          while peek p <> None && (match peek p with Some { v = ")"; _ } -> false | _ -> true) do
            args := parse_expression () :: !args;
            if match_tok p "," = None then ()
          done;
          ignore (expect p ")");
          JAssoc [("_type", JString "Call"); ("func", JString v); ("args", JList (List.rev !args)); ("lineno", JInt line); ("col_offset", JInt col)]
        ) else
          JAssoc [("_type", JString "Name"); ("id", JString v); ("lineno", JInt line); ("col_offset", JInt col)]
    | None -> failwith "Unexpected EOF in expression"
  in

  let body = ref [] in
  while peek p <> None do
    body := parse_toplevel () :: !body
  done;
  JAssoc [("ok", JBool true); ("ast", JAssoc [("_type", JString "Program"); ("body", JList (List.rev !body))])]

let parse_json_str (s : string) : json =
  let len = String.length s in
  let i = ref 0 in
  let skip_space () =
    while !i < len && (s.[!i] = ' ' || s.[!i] = '\t' || s.[!i] = '\n' || s.[!i] = '\r') do incr i done in
  let parse_string () =
    incr i;
    let buf = Buffer.create 16 in
    let esc = ref false in
    let done_s = ref false in
    while !i < len && not !done_s do
      let c = s.[!i] in
      if !esc then (
        (match c with 'n' -> Buffer.add_char buf '\n' | 'r' -> Buffer.add_char buf '\r' | 't' -> Buffer.add_char buf '\t' | _ -> Buffer.add_char buf c);
        esc := false;
        incr i
      ) else if c = '\\' then (
        esc := true;
        incr i
      ) else if c = '"' then (
        done_s := true;
        incr i
      ) else (
        Buffer.add_char buf c;
        incr i
      )
    done;
    Buffer.contents buf in
  let rec parse_val () : json =
    skip_space ();
    if !i >= len then JNull
    else match s.[!i] with
    | '"' -> JString (parse_string ())
    | '[' ->
        incr i; skip_space ();
        if !i < len && s.[!i] = ']' then (incr i; JList [])
        else (
          let elems = ref [parse_val ()] in
          skip_space ();
          while !i < len && s.[!i] = ',' do
            incr i;
            elems := parse_val () :: !elems;
            skip_space ()
          done;
          skip_space ();
          if !i < len && s.[!i] = ']' then incr i;
          JList (List.rev !elems)
        )
    | '{' ->
        incr i; skip_space ();
        if !i < len && s.[!i] = '}' then (incr i; JAssoc [])
        else (
          let parse_kv () =
            skip_space ();
            let k = if !i < len && s.[!i] = '"' then parse_string () else "" in
            skip_space ();
            if !i < len && s.[!i] = ':' then incr i;
            let v = parse_val () in
            (k, v) in
          let pairs = ref [parse_kv ()] in
          skip_space ();
          while !i < len && s.[!i] = ',' do
            incr i;
            pairs := parse_kv () :: !pairs;
            skip_space ()
          done;
          skip_space ();
          if !i < len && s.[!i] = '}' then incr i;
          JAssoc (List.rev !pairs)
        )
    | 't' -> i := !i + 4; JBool true
    | 'f' -> i := !i + 5; JBool false
    | 'n' -> i := !i + 4; JNull
    | _ ->
        let start_i = !i in
        while !i < len && ((s.[!i] >= '0' && s.[!i] <= '9') || s.[!i] = '-' || s.[!i] = '.') do incr i done;
        let num_str = String.sub s start_i (!i - start_i) in
        if String.contains num_str '.' then JFloat (float_of_string num_str)
        else JInt (int_of_string num_str)
  in
  parse_val ()

let rec unparse_json = function
  | JAssoc assoc -> (
      match List.assoc_opt "_type" assoc with
      | Some (JString "Program") ->
          let body = match List.assoc_opt "body" assoc with Some (JList l) -> l | _ -> [] in
          String.concat "\n\n" (List.map unparse_json body)
      | Some (JString "Module") ->
          let name = match List.assoc_opt "name" assoc with Some (JString s) -> s | _ -> "Unnamed" in
          let body = match List.assoc_opt "body" assoc with Some (JList l) -> l | _ -> [] in
          "mod " ^ name ^ " do\n  " ^ String.concat "\n  " (List.map unparse_json body) ^ "\nend"
      | Some (JString "Actor") ->
          let name = match List.assoc_opt "name" assoc with Some (JString s) -> s | _ -> "Unnamed" in
          let handlers = match List.assoc_opt "handlers" assoc with Some (JList l) -> l | _ -> [] in
          "actor " ^ name ^ " do\n  " ^ String.concat "\n  " (List.map unparse_json handlers) ^ "\nend"
      | Some (JString "Needs") ->
          let cap = match List.assoc_opt "capability" assoc with Some (JString s) -> s | _ -> "" in
          "needs " ^ cap
      | Some (JString "Use") ->
          let m = match List.assoc_opt "module" assoc with Some (JString s) -> s | _ -> "" in
          "use " ^ m
      | Some (JString "OnHandler") ->
          let msg = match List.assoc_opt "message" assoc with Some (JString s) -> s | _ -> "" in
          let body = match List.assoc_opt "body" assoc with Some (JList l) -> l | _ -> [] in
          "on " ^ msg ^ " do\n    " ^ String.concat "\n    " (List.map unparse_json body) ^ "\n  end"
      | Some (JString "FunctionDef") ->
          let name = match List.assoc_opt "name" assoc with Some (JString s) -> s | _ -> "" in
          let vis = match List.assoc_opt "visibility" assoc with Some (JString "private") -> "pfn" | _ -> "fn" in
          let params = match List.assoc_opt "params" assoc with Some (JList l) -> l | _ -> [] in
          let ret_str = match List.assoc_opt "return_type" assoc with Some (JString s) -> " : " ^ s | _ -> "" in
          let body = match List.assoc_opt "body" assoc with Some (JList l) -> l | _ -> [] in
          let p_str = String.concat ", " (List.map (fun p ->
            match p with
            | JAssoc pa -> (
                let pname = match List.assoc_opt "name" pa with Some (JString s) -> s | _ -> "" in
                let ptype = match List.assoc_opt "type" pa with Some (JString s) -> " : " ^ s | _ -> "" in
                pname ^ ptype
              )
            | _ -> ""
          ) params) in
          vis ^ " " ^ name ^ "(" ^ p_str ^ ")" ^ ret_str ^ " do\n  " ^ String.concat "\n  " (List.map unparse_json body) ^ "\nend"
      | Some (JString "Let") ->
          let name = match List.assoc_opt "name" assoc with Some (JString s) -> s | _ -> "" in
          let val_str = match List.assoc_opt "value" assoc with Some v -> unparse_json v | _ -> "" in
          "let " ^ name ^ " = " ^ val_str
      | Some (JString "Match") ->
          let expr_str = match List.assoc_opt "expr" assoc with Some v -> unparse_json v | _ -> "" in
          let arms = match List.assoc_opt "arms" assoc with Some (JList l) -> l | _ -> [] in
          let arms_str = String.concat "\n  " (List.map (fun a ->
            match a with
            | JAssoc aa -> (
                let pat = match List.assoc_opt "pattern" aa with Some v -> unparse_json v | _ -> "" in
                let body = match List.assoc_opt "body" aa with Some v -> unparse_json v | _ -> "" in
                pat ^ " -> " ^ body
              )
            | _ -> ""
          ) arms) in
          "match " ^ expr_str ^ " do\n  " ^ arms_str ^ "\nend"
      | Some (JString "ConstructorPattern") ->
          let name = match List.assoc_opt "name" assoc with Some (JString s) -> s | _ -> "" in
          let args = match List.assoc_opt "args" assoc with Some (JList l) -> l | _ -> [] in
          if args = [] then name else name ^ "(" ^ String.concat ", " (List.map unparse_json args) ^ ")"
      | Some (JString "VariablePattern") ->
          (match List.assoc_opt "name" assoc with Some (JString s) -> s | _ -> "")
      | Some (JString "BinOp") ->
          let op = match List.assoc_opt "op" assoc with Some (JString s) -> s | _ -> "+" in
          let l = match List.assoc_opt "left" assoc with Some v -> unparse_json v | _ -> "" in
          let r = match List.assoc_opt "right" assoc with Some v -> unparse_json v | _ -> "" in
          l ^ " " ^ op ^ " " ^ r
      | Some (JString "Call") ->
          let func = match List.assoc_opt "func" assoc with Some (JString s) -> s | _ -> "" in
          let args = match List.assoc_opt "args" assoc with Some (JList l) -> l | _ -> [] in
          func ^ "(" ^ String.concat ", " (List.map unparse_json args) ^ ")"
      | Some (JString "Name") ->
          (match List.assoc_opt "id" assoc with Some (JString s) -> s | _ -> "")
      | Some (JString "Constant") ->
          (match List.assoc_opt "subtype" assoc with
           | Some (JString "string") ->
               let v = match List.assoc_opt "value" assoc with Some (JString s) -> s | _ -> "" in
               "\"" ^ v ^ "\""
           | Some (JString "boolean") ->
               (match List.assoc_opt "value" assoc with Some (JBool b) -> if b then "true" else "false" | _ -> "false")
           | _ ->
               (match List.assoc_opt "value" assoc with
                | Some (JInt i) -> string_of_int i
                | Some (JFloat f) -> string_of_float f
                | Some (JString s) -> s
                | _ -> ""))
      | _ -> ""
    )
  | _ -> ""
