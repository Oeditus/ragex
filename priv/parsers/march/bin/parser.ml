(* Pure OCaml March Parser Executable *)

let () =
  let source =
    if Array.length Sys.argv > 1 && Sys.file_exists Sys.argv.(1) then
      let ic = open_in Sys.argv.(1) in
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic; s
    else
      let buf = Buffer.create 1024 in
      try
        while true do
          Buffer.add_string buf (read_line ());
          Buffer.add_char buf '\n'
        done;
        Buffer.contents buf
      with End_of_file -> Buffer.contents buf
  in
  try
    let json_ast = March_ast.Ast.parse_program_json source in
    print_endline (March_ast.Ast.json_to_string json_ast)
  with e ->
    let err_msg = March_ast.Ast.escape_str (Printexc.to_string e) in
    print_endline ("{\"ok\":false,\"error\":{\"type\":\"ParseError\",\"msg\":" ^ err_msg ^ "}}")
