#import "Basic";
#import "Compiler";

#run {
    set_build_options_dc(.{do_output=false});
    w := compiler_create_workspace("Voronoi");
    if !w {
        print("ERROR: Workspace creation failed.\n");
        return;
    }
    bo := get_build_options(w);
    bo.output_executable_name = "voronoi";
    bo.dead_code_elimination = .NONE;
    set_build_options(bo, w);
    add_build_file("./voronoi.jai", w);
}
