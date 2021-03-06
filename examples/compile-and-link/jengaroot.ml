
open Core.Std
open Async.Std
open Jenga_lib.Api_v2
let return = Depends.return
let ( *>>| ) = Depends.map
let ( *>>= ) = Depends.bind

(* Example to show the programmatic setup of compilation & link rules for a directory of
   source files.

   This example mimics the standard compile/link phases found in many languages.  For the
   purposes of this example, files suffixed ".1" are regarded as source.  Suffixes .2 .3
   etc. are various stages of compilation (final stage number .3 defined by n_max below).
   The files from the final stage are linked together as: the.library.

   The compiler is "cp" and the linker "cat" !

   The example shows use of a glob patten (matching all source files) as dependency of the
   rule generator. This dependency triggers the generator to be re-run whenever new files
   appear with suffix .1 or existing .1 files are removed.  This has the effect of setting
   up the necessary compilation rules for the new source, and adapting the link rule.

   The example also shows how a rule-scheme may generate rules in different directories.
   In particular, if jenga is started in any subdir, it will setup rules & build whatever
   sources are found in that directory.
*)

let message fmt = ksprintf (fun s -> Printf.printf "USER : %s\n%!" s) fmt
let rec upto i j = if i > j then [] else i :: upto (i+1) j

let simple_rule ~targets ~deps ~action =
  Rule.create ~targets (
    Depends.all_unit deps *>>| fun () ->
    action)

(* /bin/cp is our compiler *)
let cp_rule ~source ~target =
  simple_rule ~targets:[target] ~deps:[Depends.path source]
    ~action:(
      Action.shell ~dir:(Path.dirname target)
        ~prog:"/bin/cp"
        ~args:[
          (Path.basename source);
          (Path.basename target);
        ]
    )

(* N stages of compilation, from name.1 -> name.2 -> .. -> name.N
   The .1 suffixed files are our sources.
*)
let mk_file ~dir name i = Path.relative ~dir (sprintf "%s.%d" name i)

(* define the compilation rules for a given name *)
let compile_stages ~dir ~name ~n_stages =
  List.map (upto 2 n_stages) ~f:(fun i ->
    cp_rule ~source:(mk_file ~dir name (i-1)) ~target:(mk_file ~dir name i)
  )

(* cat is our linker *)
let link_files_by_concatenation ~sources ~target =
  simple_rule ~targets:[target] ~deps:(List.map sources ~f:Depends.path)
    ~action:(
      Action.shell ~dir:(Path.dirname target)
        ~prog:"/bin/bash"
        ~args:[
          "-c";
          sprintf "echo -n $(cat %s) > %s"
            (String.concat ~sep:" " (List.map sources ~f:Path.basename))
            (Path.basename target)
        ]
    )

let name_of_path path =
  fst (String.rsplit2_exn (Path.basename path) ~on:'.')

let scheme =
  Scheme.create ~tag:"the-scheme" (fun ~dir ->
    (* Rule setup depends on all sources found in the directory *)
    let dot1s = Glob.create ~dir "*.1" in
    let n_max = 3 in
    Generator.create (
      Depends.glob dot1s *>>= fun dot1_paths ->
      let names = List.map dot1_paths ~f:name_of_path in
      message "Generate rules: %s, names = %s"
        (Path.to_string dir) (String.concat ~sep:" " names);
      let compile_rules =
        List.concat_map names ~f:(fun name ->
          compile_stages ~dir ~name ~n_stages:n_max
        )
      in
      let fully_compiled_files =
        List.map names ~f:(fun name -> mk_file ~dir name n_max)
      in
      let the_library = Path.relative ~dir "the.library" in
      let link_rule =
        link_files_by_concatenation ~sources:fully_compiled_files ~target:the_library
      in
      let default_rule = Rule.default ~dir (Depends.path the_library) in
      return (compile_rules @ [link_rule; default_rule;])
    )
  )

let env = Env.create ["**", Some scheme]
let setup () = Deferred.return env
