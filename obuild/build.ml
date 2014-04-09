open Ext.Fugue
open Ext.Filepath
open Ext
open Types
open Helper
open Printf
open Filetype
open Analyze
open Target
open Prepare
open Gconf
open Modname
open Hier
open Buildprogs
open Dependencies
open Pp

exception CCompilationFailed of string
exception CompilationFailed of string
exception Internal_Inconsistancy of string * string

(* check that destination is valid (mtime wise) against a list of srcs and
 * if not valid gives the filepath that has changed.
 * *)
let check_destination_valid_with srcs cstate (filety, dest) =
  if Filesystem.exists dest
  then (
    let dest_time = Filesystem.getModificationTime dest in
    try Some (List.find (fun (_,path) ->
        let mtime = Filesystem.getModificationTime path in
        dest_time < mtime
      ) srcs)
    with Not_found -> None
  ) else
    Some (FileO, currentDir)

(* same as before but the list of sources is automatically determined
 * from the file DAG
*)
let check_destination_valid cstate (filety, dest) =
  let children =
    try Dag.getChildren cstate.compilation_filesdag (file_id (filety, dest))
    with Dag.DagNode_Not_found ->
      raise (Internal_Inconsistancy ((file_type_to_string filety), ("missing destination: " ^ fp_to_string dest)))
  in
  check_destination_valid_with (List.map un_file_id children) cstate (filety,dest)

(* get a nice reason of why a destination is not deemed valid against
 * the source filepath that triggered the unvalid check.
 *
 * if source filepath is empty, it means that destination doesn't exists *)
let reason_from_paths (_,dest) (srcTy,changedSrc) =
  let trim_pd_exts z =
    let n = fn_to_string z in
    if string_endswith ".d" n then fn (Filename.chop_suffix n ".d")
    else if string_endswith ".p" n then fn (Filename.chop_suffix n ".p")
    else z
  in
  if changedSrc = currentDir
  then ""
  else (
    let bdest = path_basename dest in
    let bsrc  = path_basename changedSrc  in
    match Filetype.get_extension bdest with
    | FileCMX | FileCMO -> (
        match srcTy with
        | FileCMX | FileCMO ->
          let bml = Filetype.replace_extension bdest FileML in
          let bmli = Filetype.replace_extension bdest FileMLI in
          if bml = bsrc then "Source changed"
          else if bmli = bsrc then "Interface changed"
          else ("Dependency " ^ modname_to_string (module_of_filename (trim_pd_exts bsrc)) ^ " changed " ^ fp_to_string changedSrc)
        | FileCMXA | FileCMA ->
          "Library changed " ^ fp_to_string changedSrc
        | _ ->
          "Dependencies changed " ^ fp_to_string changedSrc
      )
    | FileO ->
      let bc = Filetype.replace_extension bdest FileC in
      let bh = Filetype.replace_extension bdest FileH in
      if bc = bsrc then ("C file " ^ fn_to_string bsrc ^ " changed")
      else if bh = bsrc then ("H file " ^ fn_to_string bsrc ^ " changed")
      else ("file changed " ^ fp_to_string changedSrc)
    | _ ->
      fp_to_string changedSrc ^ " changed"
  )

let get_all_modes target =
  let compile_opts = Target.get_compilation_opts target in
  let compiled_types = Target.get_ocaml_compiled_types target in
  let all_modes = List.concat (List.map (fun ty ->
      List.map (fun cmode -> (ty, cmode)) compile_opts) compiled_types) in
  List.filter (fun (t,o) ->
      match (t,o) with (ByteCode,WithProf) -> false | _ -> true) all_modes

let annot_mode () =
  if gconf.conf_annot && gconf.conf_bin_annot then AnnotationBoth
  else if gconf.conf_annot then AnnotationText
  else if gconf.conf_bin_annot then AnnotationBin
  else AnnotationNone

let get_nb_step dag =
  let nb_step = Dag.length dag in
  let nb_step_len = String.length (string_of_int nb_step) in
  (nb_step, nb_step_len)

let buildmode_to_filety bmode = if bmode = Native then FileCMX else FileCMO
let buildmode_to_library_filety bmode = if bmode = Native then FileCMXA else FileCMA

let internal_libs_paths self_deps =
  List.map (fun (compile_opt,compile_type) ->
      ((compile_opt,compile_type), List.map (fun dep ->
           let dirname = Dist.getBuildDest (Dist.Target (LibName dep)) in
           let filety = buildmode_to_library_filety compile_type in
           let libpath = dirname </> cmca_of_lib compile_type compile_opt dep in
           (filety, libpath)
         ) self_deps)
    ) [ (Normal,Native);(Normal,ByteCode);(WithProf,Native);(WithProf,ByteCode);(WithDebug,Native);(WithDebug,ByteCode)]

(* compile C files *)
let compile_c task_index task c_file bstate task_context dag =
  let (cstate,target) = Hashtbl.find task_context task in
  let cbits = target.target_cbits in
  let c_dir_spec = {
    include_dirs = cstate.compilation_c_include_paths;
    dst_dir      = cstate.compilation_builddir_c;
    src_dir      = cbits.target_cdir
  } in
  let dest = (FileO, c_dir_spec.dst_dir </> o_from_cfile c_file) in
  (match check_destination_valid cstate dest with
   | None            -> Scheduler.FinishTask task
   | Some src_changed ->
     let reason = reason_from_paths dest src_changed in
     let (nb_step,nb_step_len) = get_nb_step dag in
     verbose Report "[%*d of %d] Compiling C %-.30s%s\n%!" nb_step_len task_index nb_step (fn_to_string c_file)
       (if reason <> "" then "    ( " ^ reason ^ " )" else "");
     let cflags = cbits.target_cflags in
     Scheduler.AddProcess (task, runCCompile bstate.bstate_config c_dir_spec cflags c_file)
  )

(* compile a set of modules in directory into a pack *)
let compile_directory task_index task h task_context dag =
  let (cstate,target) = Hashtbl.find task_context task in
  let pack_opt = hier_parent h in
  (* get all the modules defined at level h+1 *)
  let modules_task = Taskdep.linearize cstate.compilation_dag Taskdep.FromParent [task] in
  let filter_modules t : hier option = match t with
    | (CompileC _) | (CompileInterface _) | (LinkTarget _) | (CheckTarget _) -> None
    | (CompileDirectory m) | (CompileModule m) -> if hier_lvl m = (hier_lvl h + 1) then Some m else None
  in
  let modules = List.rev $ list_filter_map filter_modules modules_task in
  let all_modes = get_all_modes target in
  let annot_mode = annot_mode () in
  (* directory never have interface (?) so we serialize the native/bytecode creation.
   * the mtime checking is sub-optimal. low hanging fruits warning *)
  let tasks_ops : (string * Scheduler.call) option list list =
    let (byte_list,native_list) = List.partition (fun (t,_) -> t = ByteCode) all_modes in
    (List.map (fun pair_list ->
         List.map (fun (build_mode, comp_opt) ->
             let dest = (FileCMI, cmi_of_hier (cstate.compilation_builddir_ml comp_opt) h) in
             let mdeps = List.map (fun m ->
                 (FileCMI, cmi_of_hier (cstate.compilation_builddir_ml comp_opt) m)) modules in
             let dir = cstate.compilation_builddir_ml comp_opt in
             let fcompile = (fun () -> runOcamlPack dir dir annot_mode build_mode pack_opt h modules) in
             match check_destination_valid_with mdeps cstate dest with
             | None            -> None
             | Some src_changed -> Some (reason_from_paths dest src_changed, fcompile)
           ) pair_list
       ) [byte_list; native_list])
  in
  let (reason, ops) =
    (*[ [(r,f)] ]*)
    let l : (string * Scheduler.call) list list = List.map maybes_to_list tasks_ops in
    match List.filter (fun x -> x <> []) l with
    | []                -> ("", [])
    | [] :: ys          -> assert false
    | ((r,x)::xs) :: ys -> (r, (x :: List.map snd xs) :: List.map (List.map snd) ys)
  in
  if ops <> [] then (
    let (nb_step,nb_step_len) = get_nb_step dag in
    verbose Report "[%*d of %d] Packing %-.30s%s\n%!" nb_step_len task_index nb_step (hier_to_string h) reason;
    Scheduler.AddTask (task, ops)
  ) else
    Scheduler.FinishTask task

let dep_descs is_intf hdesc bstate cstate target h =
  let self_deps = Analyze.get_internal_library_deps bstate.bstate_config target in
  let internal_libs_paths_all_modes = internal_libs_paths self_deps in
  let module_deps = hdesc.dep_cwd_modules in
  let compile_opts = Target.get_compilation_opts target in
  let all_modes = get_all_modes target in
  if is_intf then (
    let intf_desc =
      match hdesc.module_intf_desc with
      | None      -> failwith "assertion error, task interface and no module_intf"
      | Some intf -> intf
    in
    List.map (fun comp_opt ->
        let dest = (FileCMI, cmi_of_hier (cstate.compilation_builddir_ml comp_opt) h) in
        let src  = [ (FileMLI, intf_desc.module_intf_path) ] in
        let m_deps = List.map (fun module_dep ->
            (FileCMI, cmi_of_hier (cstate.compilation_builddir_ml comp_opt) module_dep)) module_deps in
        let internal_deps = List.assoc (comp_opt,ByteCode) internal_libs_paths_all_modes in
        (dest,Interface,comp_opt, src @ internal_deps @ m_deps)
      ) compile_opts
  ) else (
    List.map (fun (compiled_ty, comp_opt) ->
        let file_compile_ty = buildmode_to_filety compiled_ty in
        let dest = (file_compile_ty, cmc_of_hier compiled_ty (cstate.compilation_builddir_ml comp_opt) h) in
        let src = (match hdesc.module_intf_desc with
              None -> []
            | Some intf -> [FileMLI,intf.module_intf_path]) @ [(FileML, hdesc.module_src_path)] in
        let m_deps = List.concat (List.map (fun module_dep ->
            [(file_compile_ty, cmc_of_hier compiled_ty (cstate.compilation_builddir_ml comp_opt) module_dep);
             (FileCMI, cmi_of_hier (cstate.compilation_builddir_ml comp_opt) module_dep)]
          ) module_deps) in
        let internal_deps = List.assoc (comp_opt,compiled_ty) internal_libs_paths_all_modes in
        (dest,Compiled compiled_ty,comp_opt,src @ internal_deps @ m_deps)
      ) all_modes
  )

(* add a OCaml module or interface compilation process *)
let compile_module task_index task is_intf h bstate task_context dag =
  let all = Hashtbl.find_all task_context task in
  let process_one_target cstate target =
    let pack_opt = hier_parent h in
    let hdesc =
      let desc = Hashtbl.find cstate.compilation_modules h in
      match desc.module_ty with
      | DescFile z -> z
      | DescDir _  ->
        failwith (sprintf "internal error compile module on directory (%s). steps dag internal error"
                    (hier_to_string h))
    in
    let src_path = path_dirname hdesc.module_src_path in
    let use_thread = hdesc.module_use_threads in
    let dir_spec = {
      src_dir      = src_path;
      dst_dir      = currentDir;
      include_dirs = [currentDir]
    } in
    let dep_descs = dep_descs is_intf hdesc bstate cstate target h in
    let annot_mode = annot_mode () in
    let rec check invalid descs = match descs with
      | []                                  -> (None, [])
      | (dest,build_mode,comp_opt,srcs) :: xs ->
        let r_dir_spec = {
          dir_spec with
          dst_dir = cstate.compilation_builddir_ml comp_opt <//> hier_to_dirpath h;
          include_dirs = cstate.compilation_include_paths comp_opt h
        } in
        let fcompile =
          (build_mode,(fun () -> runOcamlCompile r_dir_spec use_thread annot_mode build_mode comp_opt
                          pack_opt hdesc.module_use_pp hdesc.module_oflags h)) in
        if invalid
        then (
          let (_, ys) = check invalid xs in
          (Some "", fcompile :: ys)
        ) else (
          match check_destination_valid_with srcs cstate dest with
          | None            -> check false xs
          | Some src_changed ->
            let reason = reason_from_paths dest src_changed in
            let (_, ys) = check true xs in
            (Some reason, fcompile :: ys)
        )
    in
    (check false dep_descs, hdesc)
  in
  let all = List.map (fun (c,t) -> process_one_target c t) all in
  let ((compilation_reason, check_fun_list), hdesc) = List.hd all in
  match compilation_reason with
  | None        -> Scheduler.FinishTask task
  | Some reason -> (* if the module has an interface, we create one list, so everything can be run in parallel,
                      * otherwise we partition the build_mode functions in build_modes group. *)
    let fun_lists check_fun_list hdesc =
      if is_intf || module_file_has_interface hdesc
      then [List.map snd check_fun_list]
      else let (l1,l2) = List.partition (fun (x,_) -> x = Compiled Native) check_fun_list in
        List.filter (fun x -> List.length x > 0) [List.map snd l1; List.map snd l2]
    in
    let all_fun_lists = List.fold_left  (fun l ((_,check), hdesc) ->
        let funlist = fun_lists check hdesc in
        l @ funlist) [] all in

    let verb = if is_intf then "Intfing" else "Compiling" in
    let (nb_step, nb_step_len) = get_nb_step dag in
    verbose Report "[%*d of %d] %s %-.30s%s\n%!" nb_step_len task_index nb_step verb (hier_to_string h)
      (if reason <> "" then "    ( " ^ reason ^ " )" else "");
    Scheduler.AddTask (task, all_fun_lists)

let wait_for_files cdep_files =
  List.for_all (fun f ->
      let test = Filesystem.exists f in
      if not test then
        verbose Debug "warning: (temporarily?) missing file %s" (fp_to_string f);
      test
    ) cdep_files

let link_c cstate clib_name =
  let lib_name = cstate.compilation_builddir_c </> fn clib_name in
  let cdep_files = List.map (fun x -> cstate.compilation_builddir_c </> o_from_cfile x) cstate.compilation_csources in
  (* Not sure why it is necessary ... gcc seems to return before the files are ready. *)
  while not (wait_for_files cdep_files) do
    ignore (Unix.select [] [] [] 0.02)  (* sleep 1/50 second *)
  done;
  if gconf.conf_ocamlmklib then
    [[(fun () -> runCLinking LinkingShared cdep_files lib_name)]]
  else (
    let so_file = cstate.compilation_builddir_c </> fn ("dll" ^ clib_name ^ ".so") in
    let a_file = cstate.compilation_builddir_c </> fn ("lib" ^ clib_name ^ ".a") in
    [[(fun () -> runCLinking LinkingShared cdep_files so_file)];
     [(fun () -> runAr a_file cdep_files)];
     [(fun () -> runRanlib a_file)]]
  )

let link task_index task bstate task_context dag =
  let (cstate,target) = Hashtbl.find task_context task in
  let cbits = target.target_cbits in
  let compiled = get_compilation_order cstate in
  verbose Debug "  compilation order: %s\n" (Utils.showList "," hier_to_string compiled);
  let selfDeps = Analyze.get_internal_library_deps bstate.bstate_config target in
  verbose Debug "  self deps: %s\n" (Utils.showList "," lib_name_to_string selfDeps);
  let selfLibDirs = List.map (fun dep -> Dist.getBuildDest (Dist.Target (LibName dep))) selfDeps in
  let internal_cclibs = if cstate.compilation_csources <> []
    then [Target.get_target_clibname target]
    else []
  in
  let cclibs = List.concat (List.map (fun (cpkg,_) ->
      List.map (fun x -> "-l" ^ x)
        (Analyze.get_c_pkg cpkg bstate.bstate_config).cpkg_conf_libs) cbits.target_cpkgs)
               @ List.map (fun x -> "-L" ^ fp_to_string x) selfLibDirs
               @ List.map (fun x -> "-l" ^ x) (cbits.target_clibs @ internal_cclibs)
  in
  let pkgDeps = Analyze.get_pkg_deps target bstate.bstate_config in
  verbose Verbose "package deps: [%s]\n" (Utils.showList "," lib_name_to_string pkgDeps);
  let useThreadLib =
    if List.mem (lib_name_of_string "threads") pkgDeps || List.mem (lib_name_of_string "threads.posix") pkgDeps
    then WithThread
    else NoThread
  in
  let cfunlist = if cstate.compilation_csources <> [] then
      link_c cstate (Target.get_target_clibname target)
    else [] in
  let all_modes = get_all_modes target in
  let funlist = List.fold_left (fun flist (compiledType,compileOpt) ->
      let buildDeps =  if is_target_lib target then []
        else list_filter_map (fun dep ->
            match Hashtbl.find bstate.bstate_config.project_dep_data dep with
            | Internal -> Some (in_current_dir (cmca_of_lib compiledType compileOpt dep))
            | System   ->
              let meta = Analyze.get_pkg_meta dep bstate.bstate_config in
              let pred = match compiledType with
                | Native    -> Meta.Pred_Native
                | ByteCode  -> Meta.Pred_Byte
              in
              let archives = Meta.getArchiveWithFilter meta dep pred in
              match archives with
              | []              -> None
              | archiveFile::_  -> Some (in_current_dir $ fn (snd archiveFile))
          ) pkgDeps
      in
      let dest = match target.target_name with
        | LibName libname ->
          cstate.compilation_builddir_ml Normal </> cmca_of_lib compiledType compileOpt libname
        | _ ->
          let outputName = Utils.to_exe_name compileOpt compiledType (Target.get_target_dest_name target) in
          cstate.compilation_builddir_ml Normal </> outputName
      in
      let linking_paths_of compileOpt = match compileOpt with
        | Normal    -> cstate.compilation_linking_paths
        | WithDebug -> cstate.compilation_linking_paths_d
        | WithProf  -> cstate.compilation_linking_paths_p
      in
      let destTime = Filesystem.getModificationTime dest in
      let depsTime =
        try Some (List.find (fun p -> destTime < Filesystem.getModificationTime p)
                    (List.map (fun m -> cmc_of_hier compiledType (cstate.compilation_builddir_ml compileOpt) m)
                       compiled))
        with Not_found -> None
      in
      if depsTime <> None then (
        let (nb_step,nb_step_len) = get_nb_step dag in
        verbose Report "[%*d of %d] Linking %s %s\n%!" nb_step_len task_index nb_step
          (if is_target_lib target then "library" else "executable") (fp_to_string dest);
        (fun () -> runOcamlLinking (linking_paths_of compileOpt) compiledType
            (if is_target_lib target then LinkingLibrary else LinkingExecutable)
            compileOpt useThreadLib cclibs buildDeps compiled dest) :: flist
      ) else flist
    ) [] all_modes in
  if funlist <> [] then
    Scheduler.AddTask (task, cfunlist @ [funlist])
  else
    Scheduler.FinishTask task

let get_destination_files target =
  let all_modes = get_all_modes target in
  match target.Target.target_name with
  | LibName libname ->
    List.map (fun (typ,opt) -> cmca_of_lib typ opt libname) all_modes
  | ExeName e | TestName e | BenchName e | ExampleName e ->
    List.map (fun (ty,opt) ->
        Utils.to_exe_name opt ty (Target.get_target_dest_name target)
      ) all_modes

let sanity_check build_dir target =
  let files = get_destination_files target in
  let allOK = List.for_all (fun f ->
      let test = Filesystem.exists (build_dir </> f) in
      if not test then
        verbose Debug "warning: missing file %s" (fp_to_string (build_dir </> f));
      test
    ) files in
  if not allOK
  then verbose Report "warning: some target file appears to be missing";
  ()

let check task_index task task_context dag =
  let (cstate,target) = Hashtbl.find task_context task in
  let buildDir = Dist.getBuildDest_path (Dist.Target target.target_name) in
  let (nb_step,nb_step_len) = get_nb_step dag in
  verbose Report "[%*d of %d] Checking %s\n%!" nb_step_len task_index nb_step (fp_to_string buildDir);
  sanity_check buildDir target;
  Scheduler.FinishTask task

(* compile will process the compilation DAG,
 * which will compile all C sources and OCaml modules.
*)
let compile (bstate: build_state) task_context dag =
  let taskdep = Taskdep.init dag in
  (* a compilation task has finished, terminate the process,
     * and process the result *)
  let schedule_finish (task, st) is_done =
    (match Process.terminate (task, st) with
     | Process.Success (_, warnings, _) ->
       (* TODO: store warnings for !isDone and print them if they are different when isDone *)
       if is_done then print_warnings warnings
     | Process.Failure er            -> match task with
       | CompileC _ -> raise (CCompilationFailed er)
       | _          -> raise (CompilationFailed er)
    );
    if is_done then
      Taskdep.markDone taskdep task
  in

  let dispatch (task_index, task) =
    match task with
    | (CompileC m)         -> compile_c task_index task m bstate task_context dag
    | (CompileInterface m) -> compile_module task_index task true m bstate task_context dag
    | (CompileModule m)    -> compile_module task_index task false m bstate task_context dag
    | (CompileDirectory m) -> compile_directory task_index task m task_context dag
    | (LinkTarget t)       -> link task_index task bstate task_context dag
    | (CheckTarget t)      -> check task_index task task_context dag
  in

  let stat = Scheduler.schedule gconf.conf_parallel_jobs taskdep dispatch schedule_finish in
  verbose Verbose "schedule finished: #processes=%d max_concurrency=%d\n" stat.Scheduler.nb_processes
    stat.Scheduler.max_runqueue;
  ()

let build_exe bstate exe =
  let target = Project.exe_to_target exe in
  let modules = [hier_of_filename exe.Project.exe_main] in
  let task_context = Hashtbl.create 64 in
  let build_dir = Dist.createBuildDest (Dist.Target target.target_name) in
  let cstate = prepare_target bstate build_dir target modules in
  List.iter (fun n -> Hashtbl.add task_context n (cstate,target))
    (Dag.getNodes cstate.compilation_dag);
  compile bstate task_context cstate.compilation_dag

let build_dag bstate proj_file targets_dag =
  let dag = Dag.init () in
  let task_context = Hashtbl.create 64 in
  let taskdep = Taskdep.init targets_dag in
  let targets_deps = Hashtbl.create 64 in
  let prepare_state target modules =
    let build_dir = Dist.createBuildDest (Dist.Target target.target_name) in
    let cstate = prepare_target bstate build_dir target modules in
    List.iter (fun n -> Hashtbl.add task_context n (cstate,target))
      (Dag.getNodes cstate.compilation_dag);
    Dag.merge dag cstate.compilation_dag;
    cstate.compilation_dag
  in
  while not (Taskdep.isComplete taskdep) do
    (match Taskdep.getnext taskdep with
     | None -> failwith "no free task in targets"
     | Some (step,ntask) ->
       verbose Verbose "preparing target %s\n%!" (name_to_string ntask);
       let cur_dag = (match ntask with
        | ExeName name   ->
          let exe = Project.find_exe proj_file name in
          prepare_state (Project.exe_to_target exe) [hier_of_filename exe.Project.exe_main]
        | LibName name   ->
          let lib = Project.find_lib proj_file name in
          prepare_state (Project.lib_to_target lib) lib.Project.lib_modules
        | BenchName name ->
          let bench = Project.find_bench proj_file name in
          prepare_state (Project.bench_to_target bench) [hier_of_filename bench.Project.bench_main]
        | TestName name  ->
          let test = Project.find_test proj_file name in
          prepare_state (Project.test_to_target test) [hier_of_filename test.Project.test_main]
        | ExampleName name ->
          let example = Project.find_example proj_file name in
          prepare_state (Project.example_to_target example) [hier_of_filename example.Project.example_main]
       ) in
       if (Hashtbl.mem targets_deps ntask) then begin
         let children = Dag.getLeaves cur_dag in
         let roots = Hashtbl.find targets_deps ntask in
         List.iter (fun child ->
             List.iter (fun root ->
                 Dag.addEdge child root dag
             ) roots
         ) children
       end;
       let roots = Dag.getRoots cur_dag in (* should be LinkTarget *)
       List.iter (fun p -> Hashtbl.add targets_deps p roots) (Dag.getParents targets_dag ntask);
       Taskdep.markDone taskdep ntask
    )
  done;
  compile bstate task_context dag
