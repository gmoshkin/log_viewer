#run set_build_options_dc(.{do_output = false, write_added_strings = false});

EXE_NAME :: "log_viewer";

build :: () {
    workspace := compiler_create_workspace(EXE_NAME);
    assert(xx workspace, "Failed to create workspace");

    options := get_build_options(workspace);
    args := options.compile_time_command_line;
    config := parse_command_line_arguments(args);

    //
    // setup build options
    //

    options.output_path = #filepath;
    options.output_executable_name = EXE_NAME;

    if #complete config.build_mode == {
    case .DEBUG;
        options.backend = .X64;
        set_optimization(*options, .DEBUG);
        options.output_executable_name = sprint("%-debug", EXE_NAME);
    case .RELEASE;
        options.backend = .LLVM;
        set_optimization(*options, .OPTIMIZED);
    }

    set_build_options(options, workspace);

    //
    // specify sources
    //

    compiler_begin_intercept(workspace);

    add_build_string(tprint(#string CODE

EXE_NAME :: "%";

        CODE, EXE_NAME), workspace);

    add_build_file("main.jai", workspace);

    //
    // message loop
    //

    while true {
        base_message := compiler_wait_for_message();
        Check.do_error_checking(null, base_message);

        if base_message.kind == {
        case .COMPLETE; break;

        case .PHASE;
            message := cast(*Message_Phase) base_message;
            if message.phase == .POST_WRITE_EXECUTABLE {
                output_path := get_build_options(workspace).output_path;
                set_icon(tprint("%/%", output_path, message.executable_name));
            }
        }
    }

    compiler_end_intercept(workspace);
}

#run build();

set_icon :: (exe_full_path: string) {
    icon_file := "assets/icon.ico";

    log("Setting the icon to '%'.\n", icon_file);

    #if OS == .WINDOWS {
        #import "Windows_Resources";
        success := set_icon_by_filename(exe_full_path, icon_file);
        if !success {
            log_error("Failed to set the icon for exe '%' to filename '%'.\n", exe_full_path, icon_file);
        }
    } else {
        log_error("Setting the icon when OS==% is not yet supported.\n", OS);
    }
}

Options :: struct {
    build_mode: enum { DEBUG; RELEASE; }
}

parse_command_line_arguments :: (args: [] string) -> Options {
    options: Options;
    options.build_mode = .DEBUG;

    cursor := 1;
    while cursor < args.count {
        arg := args[cursor];
        if arg == {
            case "-"; // skip
            case "release"; options.build_mode = .RELEASE;
            case "debug";   options.build_mode = .DEBUG;
            case; break;
        }
        cursor += 1;
    }

    if cursor < args.count {
        log_error("Unexpected arguments %", advance(args, cursor));
        exit(1);
    }

    return options;
}

advance :: inline (array: [] $T, offset: s64) -> result: [] T {
    assert(array.count >= offset);
    return .{array.count - offset, array.data + offset};
}

#import "Basic";
#import "Compiler";
Check :: #import "Check";
