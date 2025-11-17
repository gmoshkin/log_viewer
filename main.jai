/*

TODO:

- context menu on text line:
    - copy line to clipboard

- when drawing text pane do 2 passes
    - first draw background colors
    - here can draw the time graph and other middle-ground stuff
    - second draw foreground

- here's an idea: instead of filterring I could add undo support, basically just
  store the history of changes and allow switching between them.
  Could even keep track of the undo tree: go back and branch into a new future.
  The ui for navigation could be as simple as 2 arrows: back and forward, but
  if there's a branch there's multiple arrows forward.

- adding text notes to anchors

- serializing the setup, save/restore

- log parsing + semantic highlighting
- preview line at scroll bar anchor hovered over with mouse
- filterring/hiding? I'm not sure yet what I want/need
- status bar
- different panes for different ui elements
- minimap (scroll bar almost does everything now)

*/

main :: () {
    Profile();

    context.logger = my_logger;
    context.print_style.struct_printer = my_struct_printer;

    log("working directory: '%'", get_working_directory());
    from_clipboard := parse_command_line_arguments();

    if run_tests_mode {
        run_tests();
        return;
    }
    // Temporary?
    run_tests();

    #if OS == .WINDOWS {
        // In order to have a hope of waiting a reasonable amount of time,
        // we need to do this stupid thing. Probably we should use CreateWaitableTimer
        // and SetWaitableTimer, but we need that for every platform.
        Windows :: #import "Windows";
        Windows.timeBeginPeriod(1);
    }

    window_size = .{ 1300, 1000 };

    #if OS == .WINDOWS {
        work_area: Windows.RECT;
        ok := Windows.SystemParametersInfoW(Windows.SPI_GETWORKAREA, 0, *work_area, 0);
        log("work_area: %", work_area);
        if ok {
            work_area_size: Vector2;
            work_area_size.x = xx (work_area.right - work_area.left);
            work_area_size.y = xx (work_area.bottom - work_area.top);

            window_size.y = work_area_size.y - 40;
        }
    }

    window = create_window(xx window_size.x, xx window_size.y, EXE_NAME,
                           background_color_rgb = .[.1, .1, .1],
                           wanted_msaa = WANTED_MSAA);

    // setup drag and drop (copy-pasted from GetRect example.jai)
    #if OS == .WINDOWS {
        // @Feature: Add user-specific typelist support.
        Windows.DragAcceptFiles(window, cast(Windows.BOOL) true);
    } else #if OS == .LINUX {
        X11 :: #import "X11";
        typelist := string.["url/url", "text/uri-list", "text/plain", "application/octet-stream"];
        X11.enable_drag_and_drop(window, typelist);
    } else #if OS == .MACOS {
        #import "Objective_C";
        #import "Objective_C/AppKit";
        types := NSArray(NSPasteboardType).arrayWithObject(NSPasteboardTypeFileURL);
        NSView.registerForDraggedTypes(window, types);
    }

    exe_path := System.get_path_of_running_executable();
    exe_dir := path_strip_filename(exe_path);
    assets_directory = sprint("%/assets", exe_dir);

    set_allocators(*escape_code_stats_pool);
    escape_code_stats_allocator = .{pool_allocator_proc, *escape_code_stats_pool};
    init(*escape_code_stats,, escape_code_stats_allocator);

    set_allocators(*the_popup_menu.pool);
    the_popup_menu.allocator = .{pool_allocator_proc, *the_popup_menu.pool};

    remember_allocators(*the_text_search_ui.text_input.buffer);

    start_parsing_thread(*the_text_buffer);

    Profile();
    filenames := get_log_filenames_from_paths(input_file_full_paths);
    request_load_text_buffer_data(*the_text_buffer, filenames, input_from_clipboard, skip_until_timestamp);
    Profile();

    reload_main_font();
    load_font("Roboto", *ui_font);
    load_font("Codetta", *ui_mono_font);

    msaa := Simp.prepare_window(window, wanted_msaa = WANTED_MSAA);
    Simp.set_render_target(window);

    redraw_reasons.allocator = temp;

    should_quit := false;
    while !should_quit {
        should_quit = update_and_draw_frame();

        reset_temporary_storage();

        sleep_milliseconds(xx (1000.0 / 60.0));
    }
}

//
// global state
//

window: Window_Type;
window_size: Vector2;
window_rect: Rectangle;
mouse: Vector2;
mouse_last_frame: Vector2;
mouse_at_click: Vector2;

mouse_focus: enum {
    NONE;
    SCROLL_BAR_SLIDER;
    SCROLL_BAR;
    SCROLL_BAR_ANCHOR;
    POPUP_TEXT_INPUT;
    POPUP_MENU;
    TEXT_SEARCH_UI;
    MAIN_TEXT_PANE;
    ANCHOR_BUTTONS;
    LEFT_COLUMN;
}

Mouse_Interaction :: enum_flags { CLICK; HOVER; }

assets_directory: string;

frame_counter := 1;
redraw_needed := false;
redraw_reasons: [..] string;
request_redraw :: (reason: string, loc := #caller_location) {
    redraw_needed = true;
    if reason then array_add(*redraw_reasons, reason);
              else array_add(*redraw_reasons, tprint("at %", loc));
}

main_font_default_pixel_height :: 14;
main_font := My_Dynamic_Font.{
    pixel_height = main_font_default_pixel_height,
};

ui_mono_font := My_Dynamic_Font.{
    pixel_height = 14,
};

ui_font := My_Dynamic_Font.{
    pixel_height = 14,
};

text_pane_rect: Rectangle;
left_column_rect: Rectangle;

window_bg_color :: #run hex_color("191919");

draggin_scroll_bar := false;
scroll_bar_rect: Rectangle;
scroll_bar_slider_rect: Rectangle;
scroll_bar_pad := 1;
scroll_bar_slider_color := #run hex_color("d0d0d0");
scroll_bar_anchor_min_width := 1.7;
scroll_bar_effective_slider_color := #run hex_color("808080");
scroll_bar_anchor_hover_color := #run hex_color("e0e0e0");
scroll_bar_rectangles_drawn: int;

hovered_scroll_bar_anchor_kind: enum { EXPLICIT; SEARCH_MATCH; };
hovered_scroll_bar_anchor_index: s64 = -1;

color_red :: #run hex_color("db0011");
color_green :: #run hex_color("00c52c");
color_blue :: #run hex_color("0069cb");
color_coral :: #run hex_color("ff8080");
color_yellow :: #run hex_color("ffdf00");
color_cyan :: #run hex_color("208c73");
color_magenta :: #run hex_color("ff00bb");
color_orange :: #run hex_color("ff6b00");
color_baby_blue :: #run hex_color("6bc8f2");
color_purple :: #run hex_color("a000ff");
color_white :: #run hex_color("ffffff");
color_brown :: #run hex_color("973f00");
color_black :: #run hex_color("000000");
color_gray :: #run hex_color("707070");

//
// main update and draw proc
//

update_and_draw_frame :: () -> bool {
    t0 := seconds_since_init();

    array_reset(*redraw_reasons);

    should_quit := false;


    Input.update_window_events();

    for Input.get_window_resizes() {
        assert(it.window == window);
        window_size.x = xx it.width;
        window_size.y = xx it.height;
        log("window_size: %", window_size);

        request_redraw("window size");
    }

    {
        x, y, ok := get_mouse_pointer_position(window, true);
        if ok {
            mouse.x = xx x;
            mouse.y = xx y;
        }
    }
    defer mouse_last_frame = mouse;
    mouse_click_any := is_click(.MOUSE_BUTTON_LEFT) || is_click(.MOUSE_BUTTON_MIDDLE) || is_click(.MOUSE_BUTTON_RIGHT);
    if mouse_click_any {
        mouse_at_click = mouse;
        request_redraw("mouse click");
    }

    //
    // reset temporary values
    //

    old_main_font_pixel_height := main_font.pixel_height;


    //
    // update rectangles dependent on window size
    //

    absolute_top := cast(s32) (window_size.y);
    absolute_bottom := cast(s32) (0);
    absolute_left := cast(s32) (0);
    absolute_right := cast(s32) (window_size.x);
    absolute_mid_x := (absolute_left + absolute_right) / 2;
    absolute_mid_y := (absolute_bottom + absolute_top) / 2;
    window_rect.top = xx window_size.y;
    window_rect.left = 0;
    window_rect.width = xx window_size.x;
    window_rect.height = xx window_size.y;

    // scroll bar info
    {
        using scroll_bar_rect;
        width  = 16;
        left   = absolute_right - width;
        top    = absolute_top;
        height = xx window_size.y;
    }

    //
    // text pane info
    //
    {
        using text_pane_rect;
        left   = absolute_left + 40;
        left = max(left, xx (main_font.line_height * 3));
        top    = absolute_top;
        width  = scroll_bar_rect.left - left;
        height = xx window_size.y;
    }
    total_line_count := the_text_buffer.line_infos.count;
    text_pane_row_count := text_pane_rect.height / main_font.line_height;

    // text ui info
    {
        using the_text_search_ui.rect;
        left = absolute_left + 100;
        top = absolute_bottom + 60;
        width = 800;
        height = xx (main_font.line_height + text_search_ui_border_width * 4);
    }

    // XXX what's the english name for поле?
    {
        using left_column_rect;
        left   = absolute_left;
        top    = absolute_top;
        width  = text_pane_rect.left - absolute_left;
        height = xx window_size.y;
    }

    //
    // scroll bar info
    //
    zoom_ratio := text_pane_row_count / cast(float) total_line_count;
    zoom_ratio = min(zoom_ratio, 1); // XXX looks sus
    scroll_bar_slider_effective_height := scroll_bar_rect.height * zoom_ratio;
    scroll_bar_slider_visible_height := max(scroll_bar_slider_effective_height, 20);
    lines_per_scroll_bar_pixel := text_pane_row_count / scroll_bar_slider_effective_height;

    //
    // drag scroll bar (do this here because to calculate the scroll bar slider rectangle)
    //
    if draggin_scroll_bar {
        mouse_moved := mouse.y - mouse_at_click.y;
        scroll_rows = scroll_rows_at_click - xx (mouse_moved * lines_per_scroll_bar_pixel);
        scroll_rows = clamp(scroll_rows, 0, total_line_count - text_pane_row_count / 2.0);
        target_scroll_rows = scroll_rows;

        if !is_down(.MOUSE_BUTTON_LEFT) {
            draggin_scroll_bar = false;
            request_redraw("stopped draggin scroll bar");
        }

        if mouse != mouse_last_frame {
            request_redraw(tprint("scroll at %", #line));
        }
    }

    // scroll bar slider rectangle
    {
        rect := *scroll_bar_rect;

        w := rect.width - scroll_bar_pad * 2;

        h := scroll_bar_slider_visible_height;
        //
        // calculate the tweak that makes it so the oversized visual slider
        // doesn't overflow at the bottom of the screen
        //
        h_diff := scroll_bar_slider_visible_height - scroll_bar_slider_effective_height;
        t := scroll_rows / cast(float) total_line_count;
        y_tweak := h_diff * t;

        x := rect.left + scroll_bar_pad;

        scroll_y := scroll_rows / lines_per_scroll_bar_pixel;
        y := rect.top - scroll_y - h + y_tweak;

        {
            using scroll_bar_slider_rect;
            left   = xx x;
            top    = xx (y + h);
            width  = xx w;
            height = xx h;
        }
    }

    //
    // update mouse focus
    //
    mouse_focus = .NONE;
    if draggin_scroll_bar || axis_aligned_rectangle_contains(scroll_bar_slider_rect, mouse) {
        mouse_focus = .SCROLL_BAR_SLIDER;
    } else if (the_popup_menu.flags & .OPEN) && axis_aligned_rectangle_contains(rectangle_of(*the_popup_menu), mouse) {
        mouse_focus = .POPUP_MENU;
    } else if (the_popup_text_input.flags & .OPEN) && axis_aligned_rectangle_contains(rectangle_of(*the_popup_text_input), mouse) {
        mouse_focus = .POPUP_TEXT_INPUT;
    } else if (the_text_search_ui.flags & .OPEN) && do_text_search_ui(*the_text_search_ui, ui_mono_font, mouse, false, do_draw=false) & .HOVER {
        mouse_focus = .TEXT_SEARCH_UI;
    } else {
        anchor_kind := hovered_scroll_bar_anchor_kind;
        // I'm not actually sure this is needed...
        mouse_in_rect := mouse - .{xx scroll_bar_rect.left, xx bottom(scroll_bar_rect)};
        anchor_index := do_scroll_bar_anchors(scroll_bar_rect, explicit_anchors, anchor_button_active_color, .GET_HOVER, mouse_in_rect, t=15);
        if anchor_index != -1 {
            anchor_kind = .EXPLICIT;
        } else {
            anchor_index = do_scroll_bar_anchors(scroll_bar_rect, search_results.matches, search_match_color, .GET_HOVER, mouse_in_rect);
            anchor_kind = .SEARCH_MATCH;
        }

        if anchor_index != -1 {
            mouse_focus = .SCROLL_BAR_ANCHOR;
        }

        if anchor_index != hovered_scroll_bar_anchor_index || anchor_kind != hovered_scroll_bar_anchor_kind {
            request_redraw("hovered scroll bar anchor changed");
            hovered_scroll_bar_anchor_index = anchor_index;
            hovered_scroll_bar_anchor_kind = anchor_kind;
        }
    }

    if mouse_focus == .NONE {
        if axis_aligned_rectangle_contains(scroll_bar_rect, mouse) {
            mouse_focus = .SCROLL_BAR;
        } else if axis_aligned_rectangle_contains(text_pane_rect, mouse) {
            mouse_focus = .MAIN_TEXT_PANE;
        } else if axis_aligned_rectangle_contains(left_column_rect, mouse) {
            hover_line_index := screen_position_to_line_index(left_column_rect, mouse.y);
            if hover_line_index >= 0 {
                mouse_focus = .ANCHOR_BUTTONS;
                if hovered_anchor_button_line != hover_line_index {
                    request_redraw("hovered anchor button changed");
                    hovered_anchor_button_line = hover_line_index;
                }
            } else {
                mouse_focus = .LEFT_COLUMN;
            }
        }
    }

    //
    // handle input events
    //

    for Input.events_this_frame {
        modifiers: enum_flags { NONE :: 0x00; CTRL :: 0x01; SHIFT :: 0x02; ALT :: 0x04; };
        if is_down(.CTRL)  modifiers |= .CTRL;
        if is_down(.SHIFT) modifiers |= .SHIFT;
        if is_down(.ALT)   modifiers |= .ALT;

        if it.type == .QUIT then should_quit = true;

        else if it.key_pressed && it.key_code == .F4 && it.shift_pressed {
            debug_break();
        }

        else if it.key_pressed && it.key_code == .F4 && it.alt_pressed {
            should_quit = true;
        }

        else if it.type == .DRAG_AND_DROP_FILES {
            filenames := get_log_filenames_from_paths(it.files);
            request_load_text_buffer_data(*the_text_buffer, filenames);
        }

        // modules/Input doesn't set it.ctrl_pressed for MOUSE_WHEEL :(
        else if it.type == .MOUSE_WHEEL && modifiers == .CTRL && !draggin_scroll_bar {
            ofs := it.wheel_delta / it.typical_wheel_delta;

            if ofs != 0 {
                main_font.pixel_height += ofs;
                main_font.pixel_height = max(main_font.pixel_height, 1);
            }
        }

        else if it.key_code == #char "0" && it.ctrl_pressed && !it.shift_pressed && !it.alt_pressed {
            main_font.pixel_height = main_font_default_pixel_height;
            main_font.pixel_height = max(main_font.pixel_height, 1);
        }

        // modules/Input doesn't set it.ctrl_pressed for MOUSE_WHEEL :(
        else if it.type == .MOUSE_WHEEL && modifiers == .SHIFT && !draggin_scroll_bar {
            ofs := it.wheel_delta / cast(float) it.typical_wheel_delta;
            pane_width_in_characters := text_pane_rect.width / main_font.mono_width;
            target_scroll_columns += -ofs * (pane_width_in_characters / 16);
            target_scroll_columns = max(target_scroll_columns, 0);
            request_redraw(tprint("scroll at %", #line));
        }

        else if it.type == .MOUSE_WHEEL && !modifiers && !draggin_scroll_bar {
            ofs := it.wheel_delta / cast(float) it.typical_wheel_delta;
            pane_height_in_lines := text_pane_rect.height / main_font.line_height;
            target_scroll_rows += -ofs * (pane_height_in_lines / 8);
            target_scroll_rows = clamp(target_scroll_rows, -text_pane_row_count / 2.0, total_line_count - text_pane_row_count / 2.0);
            request_redraw(tprint("scroll at %", #line));
        }

        else if it.key_code == xx #char "F" && it.ctrl_pressed && !(the_text_search_ui.flags & .OPEN) {
            open_text_search_ui();
            request_redraw("open search ui");
        }

        else if it.key_pressed && it.key_code == .PAGE_UP {
            target_scroll_rows += -text_pane_row_count;
            target_scroll_rows = clamp(target_scroll_rows, -text_pane_row_count / 2.0, total_line_count - text_pane_row_count / 2.0);
        } else if it.key_pressed && it.key_code == .PAGE_DOWN {
            target_scroll_rows += text_pane_row_count;
            target_scroll_rows = clamp(target_scroll_rows, -text_pane_row_count / 2.0, total_line_count - text_pane_row_count / 2.0);
        }

        else if the_popup_text_input.flags & .OPEN {
            handled := popup_text_input_handle_input_event(*the_popup_text_input, it);
            if handled continue;
        }

        else if the_text_search_ui.flags & .OPEN {
            handled := text_search_ui_handle_input_event(it);
            if handled continue;
        }

        if it.key_pressed && it.key_code == .ARROW_UP {
            target_scroll_rows += -(ifx it.shift_pressed then 10 else 1);
            target_scroll_rows = clamp(target_scroll_rows, -text_pane_row_count / 2.0, total_line_count - text_pane_row_count / 2.0);
        } else if it.key_pressed && it.key_code == .ARROW_DOWN {
            target_scroll_rows += (ifx it.shift_pressed then 10 else 1);
            target_scroll_rows = clamp(target_scroll_rows, -text_pane_row_count / 2.0, total_line_count - text_pane_row_count / 2.0);
        } else if it.key_pressed && it.key_code == .ARROW_LEFT {
            target_scroll_columns += -(ifx it.shift_pressed then 10 else 1);
            target_scroll_columns = max(target_scroll_columns, 0);
        } else if it.key_pressed && it.key_code == .ARROW_RIGHT {
            target_scroll_columns += (ifx it.shift_pressed then 10 else 1);
            target_scroll_columns = max(target_scroll_columns, 0);
        } else if it.key_pressed && it.key_code == .HOME {
            if it.ctrl_pressed {
                target_scroll_rows = 0;
            } else {
                target_scroll_columns = 0;
            }
        } else if it.key_pressed && it.key_code == .END && it.ctrl_pressed {
            target_scroll_rows = total_line_count - text_pane_row_count / 2.0;
        } else if it.key_pressed && it.ctrl_pressed && it.shift_pressed && it.key_code == #char "V" {
            Profile();
            // TODO: remove existing anchors
            request_load_text_buffer_data(*the_text_buffer, from_clipboard=true);
            Profile();
        } else if it.key_pressed && it.ctrl_pressed && it.key_code == #char "Z" {
            if it.shift_pressed
                request_buffer_text_redo(*the_text_buffer);
            else
                request_buffer_text_undo(*the_text_buffer);
        } else if it.key_pressed && it.ctrl_pressed && it.key_code == #char "Y" {
            request_buffer_text_redo(*the_text_buffer);
        }
    }

    //
    // font size changed
    //
    if main_font.pixel_height != old_main_font_pixel_height {
        old_scale := 1 / cast(float) main_font.line_height;

        reload_main_font();

        new_scale := 1 / cast(float) main_font.line_height;
        target_scroll_rows -= (text_pane_rect.top - mouse.y) * (new_scale - old_scale);
        scroll_rows = target_scroll_rows;

        request_redraw(tprint("scroll at %", #line));
    }

    //
    // update focused ui elements based on mouse click
    //

    if (mouse_focus != .POPUP_MENU) && (the_popup_menu.flags & .OPEN) && mouse_click_any {
        the_popup_menu.flags &= ~.OPEN;
        request_redraw("popup menu closed");
    }

    if (mouse_focus != .POPUP_TEXT_INPUT) && (the_popup_text_input.flags & .OPEN) && mouse_click_any {
        close_popup_text_input(*the_popup_text_input);
        request_redraw("popup text input closed");
    }

    if mouse_focus == .SCROLL_BAR_ANCHOR {
        line_index: int;
        if #complete hovered_scroll_bar_anchor_kind == {
            case .EXPLICIT;     line_index = explicit_anchors[hovered_scroll_bar_anchor_index].line_index;
            case .SEARCH_MATCH; line_index = search_results.matches[hovered_scroll_bar_anchor_index].line_index;
        }
        if is_click(.MOUSE_BUTTON_LEFT) {
            old_target_scroll_rows = target_scroll_rows;
            target_scroll_rows = xx (line_index - text_pane_row_count / 2);
        } else if is_click(.MOUSE_BUTTON_RIGHT) {
            anchor_button_open_popup_menu(line_index, mouse);
        }
    }

    if mouse_focus == .SCROLL_BAR && is_click(.MOUSE_BUTTON_LEFT) {
        pixels_from_top := top(scroll_bar_rect) - mouse.y;
        fraction_from_top := pixels_from_top / height(scroll_bar_rect);
        line_index := total_line_count * fraction_from_top;
        old_target_scroll_rows = target_scroll_rows;
        target_scroll_rows = xx (line_index - text_pane_row_count / 2);
    }

    if mouse_focus == .SCROLL_BAR_SLIDER && is_click(.MOUSE_BUTTON_LEFT) {
        draggin_scroll_bar = true;
        scroll_rows_at_click = scroll_rows;
        request_redraw("start draggin scroll bar slider");
    }

    if mouse_focus != .ANCHOR_BUTTONS && hovered_anchor_button_line != -1 {
        hovered_anchor_button_line = -1;
        request_redraw("anchor button stopped hoverring");
    }

    if mouse_focus == .ANCHOR_BUTTONS {
        if is_click(.MOUSE_BUTTON_LEFT) {
            anchor_button_toggle(hovered_anchor_button_line);
        } else if is_click(.MOUSE_BUTTON_RIGHT) {
            anchor_button_open_popup_menu(hovered_anchor_button_line, mouse);
        }
    }

    // update vertical scroll
    scroll_rows = lerp(scroll_rows, target_scroll_rows, scroll_rows_lerp_factor);
    if abs(scroll_rows - target_scroll_rows) < 0.001 then scroll_rows = target_scroll_rows;

    // update horizontal scroll
    scroll_columns = lerp(scroll_columns, target_scroll_columns, scroll_columns_lerp_factor);
    if abs(scroll_columns - target_scroll_columns) < 0.001 then scroll_columns = target_scroll_columns;

    ////////////////////////////////////////////////////////////////////////////
    // @TEMPORARY!!!  (or is it?)
    if mouse_last_frame != mouse && axis_aligned_rectangle_contains(window_rect, mouse) {
        request_redraw("mouse moved");
    }
    if target_scroll_rows != scroll_rows || target_scroll_columns != scroll_columns {
        request_redraw(tprint("scroll animation %, %", target_scroll_columns - scroll_columns, target_scroll_rows - scroll_rows));
    }
    if the_text_buffer.parsing_in_progress || the_text_buffer.current_version != the_text_buffer.request.version {
        request_redraw(tprint("%", the_text_buffer.request.type));
    }

    // if !Input.input_application_has_focus return should_quit;
    if !redraw_needed return should_quit;
    // One last redraw to update the redraw reason
    redraw_needed = (redraw_reasons.count != 0);

    //
    // render start
    //

    Simp.update_window(window);
    base_color := window_bg_color;
    Simp.clear_render_target(base_color.x, base_color.y, base_color.z, 1);

    Simp.set_shader_for_color();

    can_read_buffer := safe_to_read_buffer_data(*the_text_buffer);

    // draw text pane
    if can_read_buffer {
        profile_t0 = seconds_since_init();

        handle_mouse: Mouse_Interaction;
        handle_mouse = ifx mouse_focus == .MAIN_TEXT_PANE then .CLICK | .HOVER;
        draw_the_text_pane(*the_text_buffer, text_pane_rect, handle_mouse);
        Profile("draw_the_text_pane");

        // draw the side bars to fix the ugly text bleed over
        left_rect := window_rect;
        left_rect.width = left(text_pane_rect);
        draw_axis_aligned_rectangle(left_rect, window_bg_color);

        right_rect := window_rect;
        right_rect.left = right(text_pane_rect);
        right_rect.width -= right_rect.left;
        draw_axis_aligned_rectangle(right_rect, window_bg_color);
    }

    // draw progress bar
    if !can_read_buffer {
        font := ui_font;

        rect: Rectangle;
        rect.width = xx (window_rect.width * .6);
        rect.left = xx (window_rect.left + (window_rect.width - rect.width) * .5);
        rect.height = xx (font.line_height * 4.0);
        rect.top = xx (window_rect.top - (window_rect.height - rect.height) * .5);
        draw_axis_aligned_rectangle(rect, ui_element_middleground_color);

        y := rect.top;
        x_tweak := 0;
        y_tweak := 0;

        filenames := the_text_buffer.request.filenames;
        if filenames {
            text: string;
            if filenames.count > 1 {
                text = tprint("%*%", common_prefix(filenames), common_postfix(filenames));
            } else {
                text = copy_string(filenames[0],, temp);
            }
            w_text := Simp.prepare_text(font.regular, text);
            x := rect.left + (rect.width - w_text) * .5;
            y -= xx (font.line_height + 4.0);
            Simp.draw_prepared_text(font.regular, xx (x - x_tweak), xx (y + y_tweak), ui_element_text_color);
        }
        y -= xx font.line_height;

        {
            w_text := Simp.prepare_text(font.regular, the_text_buffer.parsing_state);
            x := rect.left + (rect.width - w_text) * .5;
            Simp.draw_prepared_text(font.regular, xx (x - x_tweak), xx (y + y_tweak), ui_element_text_color);
        }

        {
            slider_margin := 10.0;
            progress_slider: Rectangle;
            progress_slider.height = xx (font.line_height * .8);
            progress_slider.top = xx (bottom(rect) + slider_margin + progress_slider.height);

            progress_max_width := rect.width - slider_margin * 2;
            progress_slider.width = xx progress_max_width;
            progress_slider.left = xx (rect.left + slider_margin);
            draw_axis_aligned_rectangle(progress_slider, ui_element_background_color);

            if the_text_buffer.all_text
            {
                t := the_text_buffer.parsing_cursor / cast(float64, the_text_buffer.all_text.count);
                progress_slider.width = xx (progress_max_width * t);
                draw_axis_aligned_rectangle(progress_slider, main_text_pane_dim_text_color);
            }
        }
    }

    Profile("draw_line_anchors");
    //
    // draw line anchors
    //
    if safe_to_read_buffer_data(*the_text_buffer)
    {
        rect := *left_column_rect;
        x_tweak := -3;
        y_tweak := 0;

        parent_top := top(rect) + y_tweak;
        H := main_font.line_height;
        parent_right := right(rect) + x_tweak;

        // hovered anchor segment
        if active_anchor_segment[0].line_index != -1 || active_anchor_segment[1].line_index != -1 {
            above_line_index := active_anchor_segment[0].line_index;
            bellow_line_index := active_anchor_segment[1].line_index;
            // This makes perfect sense!
            assert(above_line_index <= bellow_line_index);

            color := anchor_button_active_color;
            w := 4.0;
            x_middle := parent_right - H / 2.0;
            x := x_middle - w / 2.0;

            y_top := parent_top - (above_line_index - scroll_rows + 0.5) * H + w / 2;
            y_bottom := parent_top - (bellow_line_index - scroll_rows + 0.5) * H - w / 2;
            h := y_top - y_bottom;

            draw_axis_aligned_rectangle(xx x, xx y_bottom, xx w, xx h, color);
        }

        // hovered anchor button
        if hovered_anchor_button_line != -1 {
            color := anchor_button_hover_color;
            pad := 1;
            h := H - 2 * pad;
            w := h;
            x := parent_right - w - pad;

            row_index := hovered_anchor_button_line - scroll_rows;
            y_line := parent_top - (row_index + 1) * H;
            y := y_line + pad;

            // draw_axis_aligned_rectangle(xx (parent_right - H), xx y_line, xx H, xx H, hex_color("000000"));
            draw_hollow_axis_aligned_rectangle(xx x, xx y, xx w, xx h, border = 2, color);
        }

        // active anchor buttons
        {
            color := anchor_button_active_color;
            pad := 4;
            h := H - 2 * pad;
            w := h;
            x := parent_right - w - pad;
            for explicit_anchors {
                row_index := it.line_index - scroll_rows;
                // -1 because want to draw half the button at the top of the screen (bad wording)
                if row_index < -1 continue;
                // LOL this is wrong
                if row_index > xx (rect.height * H) continue;

                y_line := parent_top - (row_index + 1) * H;
                y := y_line + pad;
                draw_axis_aligned_rectangle(xx x, xx y, xx w, xx h, it.color);
            }
        }
    }

    scroll_bar_rectangles_drawn = 0;
    Profile("draw scroll bar");
    // draw scroll bar
    if safe_to_read_buffer_data(*the_text_buffer)
    {
        parent_rect := *scroll_bar_rect;
        // draw visible scroll bar slider
        draw_axis_aligned_rectangle(scroll_bar_slider_rect, scroll_bar_slider_color);
        scroll_bar_rectangles_drawn += 1;

        x := scroll_bar_slider_rect.left;
        w := scroll_bar_slider_rect.width;

        skip_start := 0.0;
        skipped_colors: [..] Vector4;
        skipped_colors.allocator = temp;

        // draw log ranges of same source
        for i: 0..the_text_buffer.log_ranges_of_source.count-2 {
            range := the_text_buffer.log_ranges_of_source[i];
            if range.source_id == SOURCE_ID_UNKNOWN continue;

            y_top := parent_rect.top - range.start_index / cast(float) lines_per_scroll_bar_pixel;
            y_bottom := parent_rect.top - the_text_buffer.log_ranges_of_source[i + 1].start_index / cast(float) lines_per_scroll_bar_pixel;

            color := get_log_source_color(range.source_id);

            // not going to be visible
            if y_top - y_bottom < .5
            {
                if !skipped_colors {
                    skip_start = y_top;
                }
                array_add(*skipped_colors, color);

                if skip_start - y_bottom >= 1 {
                    color = .{};
                    q := 1.0 / skipped_colors.count;
                    for skipped_colors {
                        color += it * q;
                    }

                    draw_axis_aligned_rectangle(xx x, y_bottom, xx w, skip_start - y_bottom, color);
                    scroll_bar_rectangles_drawn += 1;

                    skipped_colors.count = 0;
                }
                continue;
            }

            draw_axis_aligned_rectangle(xx x, y_bottom, xx w, y_top - y_bottom, color);
            scroll_bar_rectangles_drawn += 1;
        }

        // draw active anchor range on scroll bar
        {
            above_line_index := active_anchor_segment[0].line_index;
            bellow_line_index := active_anchor_segment[1].line_index;
            if above_line_index != -1 || bellow_line_index != -1 {
                // Makes complete sense
                assert(above_line_index <= bellow_line_index);

                y_top := parent_rect.top - above_line_index / cast(float) lines_per_scroll_bar_pixel;
                y_bottom := parent_rect.top - bellow_line_index / cast(float) lines_per_scroll_bar_pixel;

                my_w := w / 2.5;
                my_x := x + (w - my_w) / 2;

                color := main_text_pane_dim_background_color;
                draw_axis_aligned_rectangle(xx my_x, y_bottom, xx my_w, y_top - y_bottom, color);
                scroll_bar_rectangles_drawn += 1;
            }
        }

        // draw scroll bar anchors
        {
            mouse_in_rect := mouse - .{xx scroll_bar_rect.left, xx bottom(scroll_bar_rect)};
            search_match_index := -1;
            if the_text_search_ui.flags & .OPEN
                search_match_index = do_scroll_bar_anchors(scroll_bar_rect, search_results.matches, search_match_color, .DRAW, mouse_in_rect);
            // explicit anchors have higher priority
            explicit_anchor_index := do_scroll_bar_anchors(scroll_bar_rect, explicit_anchors, anchor_button_active_color, .DRAW, mouse_in_rect, t=15);

            if mouse_focus == .SCROLL_BAR_ANCHOR {
                if explicit_anchor_index != -1 {
                    anchor := *explicit_anchors[explicit_anchor_index];
                    draw_single_scroll_bar_anchor(scroll_bar_rect, anchor.line_index, anchor.color, hover=true, t=15);
                } else if search_match_index != -1 {
                    match := search_results.matches[search_match_index];
                    color := get_log_source_color(match.source_id);
                    draw_single_scroll_bar_anchor(scroll_bar_rect, match.line_index, color, hover=true);
                }
            }
        }

        // the rest of the slider
        {
            // draw visible scroll bar slider border
            {
                slider_oversize := 2.0;
                border := 2.0;
                if mouse_focus == .SCROLL_BAR_SLIDER {
                    slider_oversize = 3.0;
                    border = 4.0;
                }
                rect := *scroll_bar_slider_rect;
                X := left(rect) - slider_oversize;
                Y := bottom(rect) - slider_oversize;
                W := width(rect) + slider_oversize;
                H := height(rect) + 2 * slider_oversize;
                draw_hollow_axis_aligned_rectangle(xx X, xx Y, xx W, xx H, border, scroll_bar_slider_color);
                scroll_bar_rectangles_drawn += 4;
            }

            // draw effective scroll bar slider
            assert(scroll_bar_slider_visible_height >= scroll_bar_slider_effective_height);
            if scroll_bar_slider_visible_height != scroll_bar_slider_effective_height {
                color := scroll_bar_effective_slider_color;
                x_pad := 1;
                x := scroll_bar_slider_rect.left + x_pad - 1;
                w := scroll_bar_slider_rect.width - 2 * x_pad;
                h := scroll_bar_slider_effective_height;
                scroll_y := cast(float, scroll_rows) / lines_per_scroll_bar_pixel;
                y := scroll_bar_rect.top - scroll_y - h;
                draw_hollow_axis_aligned_rectangle(xx x, y, xx w, xx h, 2, color);
                scroll_bar_rectangles_drawn += 4;
            }
        }
    }

    Profile();

    // draw the text search ui
    if the_text_search_ui.flags & .OPEN {
        handle_mouse := (mouse_focus == .TEXT_SEARCH_UI);
        do_text_search_ui(*the_text_search_ui, ui_mono_font, mouse, handle_mouse, do_draw=true);
    }

    // draw the popup text input
    if the_popup_text_input.flags & .OPEN {
        handle_click := (mouse_focus == .POPUP_TEXT_INPUT);
        draw_popup_text_input(*the_popup_text_input, handle_click);
    }

    // reset these before doing popup menu, because popup menu sets these up
    for *active_anchor_segment it.line_index = -1;

    // draw the popup menu
    if the_popup_menu.flags & .OPEN {
        handle_mouse: Mouse_Interaction;
        handle_mouse = ifx (mouse_focus == .POPUP_MENU) then (.HOVER | .CLICK);

        do_popup_menu(*the_popup_menu, mouse, handle_mouse, do_draw=true);
    }

    // debuggin pane
    {
        rect := window_rect;
        font := ui_font.regular;
        x := right(window_rect) - 300.0;
        y := window_rect.top - 4.0;

        builder: String_Builder; builder.allocator = temp;
        elapsed := seconds_since_init() - t0;
        print(*builder, "% %\n", frame_counter, fmt(elapsed, 6));
        print(*builder, "scroll: %, %\n", fmt(scroll_columns, 1), fmt(scroll_rows, 1));

        jump_duration, ok := calculate_last_jump_duration();
        print(*builder, "jump time: ");
        if ok {
            print_pretty_duration(*builder, jump_duration);
        } else {
            print(*builder, "?");
        }
        append(*builder, "\n");

        // print(*builder, "mouse focus: %\n", mouse_focus);
        if the_text_search_ui.flags & .OPEN print(*builder, "search matches: %\n", search_results.matches.count);
        if hovered_scroll_bar_anchor_index != -1 then print(*builder, "% %\n", hovered_scroll_bar_anchor_kind, hovered_scroll_bar_anchor_index);
        // if quicksort_duration then print(*builder, "quicksort_duration: %\n", quicksort_duration);
        if scroll_bar_rectangles_drawn then print(*builder, "scrollbar drawn quads: %\n", scroll_bar_rectangles_drawn);


        // if the_text_search_ui.completions.values {
        //     print(*builder, "matched prefix: %\n", the_text_search_ui.completions.matched_prefix_length);
        // }
        for array_view(the_text_search_ui.completions.values, 0, 16) {
            print(*builder, "%\n", it);
        }
        if the_text_search_ui.completions.values.count > 16 {
            print(*builder, "...\n");
        }

        for redraw_reasons print(*builder, "%\n", it);

        pane_text := builder_to_string(*builder,, temp);
        draw_simple_text_pane(rect, font, .{x, y}, .TOP_LEFT, pane_text, hex_color("ffffff"), hex_color("181818"));
    }

    // @TEMPORARY
    /*
    {
        rect := window_rect;
        font := ui_font.regular;
        x := window_rect.width / 2;
        y := window_rect.height / 2;

        builder: String_Builder; builder.allocator = temp;

        print(*builder, "you're pressing these keys:\n");

        space_needed := false;
        for Input.input_button_states {
            if !(it & .DOWN) continue;
            if !(it_index >= #char "A" && it_index <= #char "Z") &&
               !(it_index >= #char "0" && it_index <= #char "9") continue;

            if space_needed append(*builder, " ");
            append(*builder, cast(u8, it_index));
            space_needed = true;
        }

        pane_text := builder_to_string(*builder,, temp);
        draw_simple_text_pane(rect, font, .{xx x, xx y}, .MIDDLE, pane_text, hex_color("ffffff"), hex_color("181818"));
    }
    */

    // Scissor doesn't work? Or I don't know how to use it???
    // Simp.set_scissor(0, 100, 0, 100);
    // Simp.clear_render_target(1, 0, 0, 1);
    // Simp.clear_scissor();

    Simp.swap_buffers(window);
    Profile();
    frame_counter += 1;

    return should_quit;
}

//
// scroll bar stuff
//

scroll_rows: float64 = 0.0;
target_scroll_rows: float64 = 0.0;
old_target_scroll_rows: float64 = 0.0;

scroll_rows_lerp_factor := 0.5;
scroll_rows_at_click: float64 = 0.0;

scroll_columns := 0.0;
target_scroll_columns := 0.0;
scroll_columns_lerp_factor := 0.5;

jump_destination_row_offset :: inline () -> float64 {
    n_lines_per_screen := height(text_pane_rect) / cast(float) main_font.line_height;
    return n_lines_per_screen / 2.0 - 3;
}

get_instant_for_line :: (_line_index: int) -> Apollo_Time {
    line_index := clamp(_line_index, 0, the_text_buffer.line_infos.count - 1);
    timestamp := the_text_buffer.line_infos[line_index].timestamp;
    if timestamp.year {
        return calendar_to_apollo(timestamp);
    }

    before: Apollo_Time;
    after: Apollo_Time;

    i := line_index - 1;
    while i >= 0 {
        timestamp := the_text_buffer.line_infos[i].timestamp;
        if timestamp.year {
            before = calendar_to_apollo(timestamp);
            break;
        }
        i -= 1;
    }

    i = line_index + 1;
    while i < the_text_buffer.line_infos.count {
        timestamp := the_text_buffer.line_infos[i].timestamp;
        if timestamp.year {
            after = calendar_to_apollo(timestamp);
            break;
        }
        i += 1;
    }

    if !before return after;
    if !after return before;

    return (before + after) / 2;
}

calculate_last_jump_duration :: () -> float64, bool {
    if !safe_to_read_buffer_data(*the_text_buffer) return -1, false;
    if !the_text_buffer.line_infos return -1, false;

    old_index := cast(int, old_target_scroll_rows + jump_destination_row_offset());
    old_instant := get_instant_for_line(old_index);
    if !old_instant return 0.0, false;

    new_index := cast(int, target_scroll_rows + jump_destination_row_offset());
    new_instant := get_instant_for_line(new_index);
    if !new_instant return 0.0, false;

    diff := new_instant - old_instant;
    duration := abs(to_float64_seconds(diff));
    return duration, true;
}

// I hate this procedure
do_scroll_bar_anchors :: (parent_rect: Rectangle, anchors: [] $T, color: Vector4, $mode: enum { DRAW; GET_HOVER; }, target_in_rect: Vector2, $$t := 10.0) -> (index: s64) {
    target := target_in_rect;
    hover_color := scroll_bar_anchor_hover_color;
    color_ := color;

    hover_indexes: [..] int;
    hover_indexes.allocator = temp;
    array_reserve(*hover_indexes, 16);

    x, effective_h, w, h := scroll_bar_anchor_parameters(parent_rect, the_text_buffer.line_infos.count);
    slack :: 1.2;
    for anchors {
        y := parent_rect.top - (it.line_index + 1) * effective_h;

        // I hate how complicated this got       v this fucking zero ToT
        p0, p1, p2 := get_scroll_bar_triangle(t, 0, y + h / 2);
        hover := triangle_contains(p0, p1, p2, target) || (target.x >= 0 && target.x <= xx parent_rect.width && target.y >= y - slack && target.y <= y + h + slack);

        #if #complete mode == {
        case .DRAW;
            #if T == Search_Match_Info then color_ = get_log_source_color(it.source_id);
            else #if T == Anchor then color_ = it.color;
            inline draw_scroll_bar_anchor(x, y, w, h, t, color_, false);
            #if T == Anchor if hover || it.flags & .TEXT_VISIBLE {
                label_right := x + p1.x - 1;
                draw_simple_text_pane(window_rect, ui_font.regular, .{label_right, y}, .MIDDLE_RIGHT, it.text, ui_element_text_color, ui_element_background_color);
            }
            if hover then array_add(*hover_indexes, it_index);

        case .GET_HOVER;
            if hover {
                array_add(*hover_indexes, it_index);
            } else if hover_indexes {
                // not hovering anymore, but had some hovers, which means we're
                // past the hovered ones. I speak not good
                return hover_indexes[hover_indexes.count / 2];
            }
        }
    }

    if !hover_indexes return -1;
    // return the middle one
    return hover_indexes[hover_indexes.count / 2];
}

draw_single_scroll_bar_anchor :: (parent_rect: Rectangle, line_index: int, color: Vector4, $$t := 10.0, hover: bool) {
    x, effective_h, w, h := scroll_bar_anchor_parameters(parent_rect, the_text_buffer.line_infos.count);
    y := parent_rect.top - (line_index + 1) * effective_h;

    inline draw_scroll_bar_anchor(x, y, w, h, t, color, hover);
}

scroll_bar_anchor_parameters :: (parent_rect: Rectangle, max_count: int) -> (x: float, effective_h: float, w: float, h: float) {
    effective_h := parent_rect.height / cast(float) max_count;
    x := cast(float) parent_rect.left;
    w := cast(float) parent_rect.width;
    h := cast(float) max(scroll_bar_anchor_min_width, effective_h);

    return x, effective_h, w, h;
}

draw_scroll_bar_anchor :: (x: float, y: float, w: float, h: float, $$t: float, color: Vector4, hover: bool) {
    hover_color := scroll_bar_anchor_hover_color;


    if hover {
        draw_axis_aligned_rectangle(x, y - 1, xx w, 1, hover_color);
        draw_axis_aligned_rectangle(x, y + h, xx w, 1, hover_color);
        scroll_bar_rectangles_drawn += 2;
    }
    draw_axis_aligned_rectangle(xx x, y, xx w, h, color);
    scroll_bar_rectangles_drawn += 1;
    {
        Y := y + h / 2;
        p0, p1, p2 := get_scroll_bar_triangle(t, x, Y);
        if hover {
            draw_triangle(p0 + .{ 2, 0 }, p1 + .{ -1.333333, -2 }, p2 + .{ -1.333333, 2 }, hover_color);
        }
        draw_triangle(p0, p1, p2, color);
        scroll_bar_rectangles_drawn += 1; // not really a recangle ...
    }

}

get_scroll_bar_triangle :: ($$t: float, x: float, y: float, $x_tweak := 2.0) -> (Vector2, Vector2, Vector2) #expand {
    p0 := Vector2.{x - x_tweak, y};
    p1 := p0 + .{x_tweak - t, -t/2};
    p2 := p0 + .{x_tweak - t,  t/2};
    return p0, p1, p2;
}

//
// text pane stuff
//

main_text_pane_text_color           :: #run hex_color("e0e0e0");
main_text_pane_dim_text_color       :: #run hex_color("909090");
main_text_pane_background_color     :: #run hex_color("202020");
main_text_pane_dim_background_color :: #run hex_color("404040");

ui_element_background_color     :: #run hex_color("181818");
ui_element_middleground_color   :: #run hex_color("262626");
ui_element_border_color         :: #run hex_color("303030");
ui_element_cursor_color         :: #run hex_color("ffffff");
ui_element_text_color           :: #run hex_color("ffffff");

// @DEBUG
global_time_range_min := APOLLO_TIME_INVALID;
global_time_range_max := APOLLO_TIME_INVALID;
global_time_current_line := APOLLO_TIME_INVALID;

draw_the_text_pane :: (buffer: *Log_Text_Buffer, rect: Rectangle, handle_mouse: Mouse_Interaction) -> mouse_handled: Mouse_Interaction {
    text_color       := main_text_pane_text_color;
    background_color := main_text_pane_background_color;

    event_out: Mouse_Interaction;

    // background
    {
        h := main_font.line_height;

        x := left(rect);
        y_top := cast(float) top(rect);
        if scroll_rows < 0 then y_top += xx scroll_rows * h;

        y_bottom := cast(float) bottom(rect);
        text_height := cast(float, buffer.line_infos.count - scroll_rows) * h;
        if text_height < xx height(rect) then y_bottom = top(rect) - text_height;


        w := width(rect);
        H := y_top - y_bottom;
        draw_axis_aligned_rectangle(xx x, xx y_bottom, xx w, xx H, background_color);
    }

    pointer := mouse;
    if (the_popup_menu.flags & .OPEN) {
        pointer = the_popup_menu.at;
    }
    hover_line_index := -1;
    if (handle_mouse & .HOVER) {
        hover_line_index = screen_position_to_line_index(rect, pointer.y);
    }

    first_line := S64_MAX;
    last_line := -1;

    // text
    {
        tail := buffer.all_text;

        h := main_font.line_height;

        text_x_tweak := 4.0;
        pane_width_in_characters := (rect.width - text_x_tweak) / main_font.mono_width;

        x := rect.left + text_x_tweak;
        y_top : float = rect.top + (cast(float, scroll_rows) - 1) * h;
        text_y_tweak := -(main_font.typical_descender + main_font.max_descender) / 2.0;

        current_ansi_style := Style.{ fg_color = text_color };
        override_ansi_style: Style;
        anchor_segment_first := active_anchor_segment[0].line_index;
        anchor_segment_last := active_anchor_segment[1].line_index;

        search_matches_cursor := 0;
        line_index := 0;
        first_line = max(cast(int) floor(scroll_rows), 0);
        last_line = min(first_line + 1 + cast(int) floor(rect.height / cast(float) h), buffer.line_infos.count - 1);
        for line_index: first_line..last_line {
            info := *buffer.line_infos[line_index];
            line := get_line(buffer, line_index);

            y := y_top - (line_index * h);

            first_line = min(first_line, line_index);
            last_line = max(last_line, line_index);

            if line_index == hover_line_index {
                click_handled := do_structured_log_info(buffer, info, line_index, rect, pointer, .{x, y}, xx (handle_mouse & .CLICK));
                if click_handled then event_out |= .CLICK;
            }

            // handle log line info
            color := text_color;
            if info.source_id != SOURCE_ID_UNKNOWN {
                color = get_log_source_color(info.source_id);
            }

            // handle anchor segment
            inside_anchor_segment := (line_index >= anchor_segment_first) && (line_index <= anchor_segment_last);
            if inside_anchor_segment {
                color = main_text_pane_dim_text_color;
                override_ansi_style.fg_color = color;
                override_ansi_style.bg_color = main_text_pane_dim_background_color;

                draw_axis_aligned_rectangle(xx rect.left, xx y, xx rect.width, xx main_font.line_height, main_text_pane_dim_background_color);
            } else {
                override_ansi_style = .{};
            }

            n_columns_to_skip := cast(int) floor(scroll_columns);
            x_tweak := (scroll_columns - n_columns_to_skip) * main_font.mono_width;

            // if line_index % 2 == 0
            //     draw_axis_aligned_rectangle(xx x, xx y, xx rect.width, xx main_font.line_height, hex_color("005050"));

            // draw the actual text
            if xx line.count > scroll_columns {
                font := main_font.regular;
                if line_index == hover_line_index {
                    font = main_font.bold;
                }

                if info.escape_codes_count != 0 {
                    codes := array_view(buffer.escape_code_infos, info.escape_codes_start, info.escape_codes_count);
                    draw_text_line_with_ansi_escape_codes(main_font, line, n_columns_to_skip, xx pane_width_in_characters,
                                                          x, -x_tweak, y, text_y_tweak, color, codes, *current_ansi_style, override_ansi_style);
                } else {
                    truncated_line := advance(line, n_columns_to_skip);
                    truncated_line.count = min(truncated_line.count, xx pane_width_in_characters + 1);

                    // TODO: tabs handling (I fucking hate tabs!!!!)
                    w_text := Simp.prepare_text(font, truncated_line);
                    // This fails for unicode!
                    // assert(w_text == main_font.mono_width * truncated_line.count);

                    Simp.draw_prepared_text(font, xx (x - x_tweak), xx (y + text_y_tweak), color);
                }
            }

            // draw anchored line highlight
            anchored := get_anchor_at_line_index(line_index) != -1;
            if anchored {
                w := rect.width;
                h := 2;
                x := rect.left;
                y_tweak := -2;
                y_bottom := y + y_tweak;
                y_top := y + main_font.line_height + y_tweak;
                draw_axis_aligned_rectangle(xx x, xx y_bottom, xx w, 2, anchor_line_highlight_color);
                draw_axis_aligned_rectangle(xx x, xx y_top,    xx w, 2, anchor_line_highlight_color);
            }

            // handle search match
            if the_text_search_ui.flags & .OPEN
                // TODO @INCOMPLETE draw all matches, not just the first ones
                draw_search_match_border(rect, main_font, text_x_tweak, y, line_index, line.count, *search_matches_cursor);

        }

    }

    global_time_range_min = APOLLO_TIME_INVALID;
    global_time_range_max = APOLLO_TIME_INVALID;
    global_time_current_line = APOLLO_TIME_INVALID;

    // time stamp graph
    {
        h := main_font.line_height;
        y_top := rect.top + (cast(float, scroll_rows) - 0.5) * h;

        time_range_min := APOLLO_TIME_INVALID;
        time_range_max := APOLLO_TIME_INVALID;
        for first_line..last_line {
            info := *buffer.line_infos[it];
            if info.source_id == SOURCE_ID_UNKNOWN continue;
            if info.timestamp.year == 0 continue;

            time := calendar_to_apollo(info.timestamp);

            if it == hover_line_index then global_time_current_line = time;

            if time_range_min == APOLLO_TIME_INVALID then time_range_min = time;
            time_range_min = min(time_range_min, time);
            if time_range_max == APOLLO_TIME_INVALID then time_range_max = time;
            time_range_max = max(time_range_max, time);
        }

        global_time_range_min = time_range_min;
        global_time_range_max = time_range_max;

        time_range := to_float64_seconds(time_range_max - time_range_min);

        color: Vector4;
        if time_range < 0.1 {
            color_t := clamp(time_range, 0, 0.1) / 0.1;
            color = lerp(color_cyan, color_orange, xx color_t);
        } else {
            color_t := (clamp(time_range, 0.1, 1.0) - 0.1) / 0.9;
            color = lerp(color_orange, color_red, xx color_t);
        }

        line_width := 2.5;
        W := width(rect) - line_width;
        x_prev := cast(float) left(rect) + line_width / 2.0;
        y_prev := y_top;
        seen_timestamp := false;
        for line_index: first_line..last_line {
            y := y_top - line_index * h;

            info := *buffer.line_infos[line_index];
            if info.source_id == SOURCE_ID_UNKNOWN continue;
            if info.timestamp.year == 0 continue;

            time := calendar_to_apollo(info.timestamp);
            time_adjusted := time - time_range_min;
            adjusted_seconds := to_float64_seconds(time_adjusted);
            t := adjusted_seconds / time_range;

            if isnan(t) then t = 0.5;

            x := cast(float, left(rect) + line_width / 2.0 + W * t);

            if !seen_timestamp {
                x_prev, y_prev = x, y;
                seen_timestamp = true;
            }

            draw_fat_line(.{x_prev, y_prev}, .{x, y}, line_width, color);

            x_prev, y_prev = x, y;
        }
    }

    return event_out;
}

do_structured_log_info :: (buffer: *Log_Text_Buffer, info: *Log_Line_Info, line_index: int, parent_rect: Rectangle, mouse: Vector2, origin: Vector2, handle_click: bool) -> click_handled: bool {
    for type_info(Log_Info_Piece_Type).values {
        type := cast(Log_Info_Piece_Type) it;
        if type == .NONE continue;
        if !info_contains(info, type) continue;

        _, start, count_u8 := inline lookup_log_info(buffer, info, type);
        count := cast(int) count_u8;
        if count == U8_MAX {
            line := get_line(buffer, line_index);
            count = line.count - start;
        }
        x_start := origin.x + (start - scroll_columns) * main_font.mono_width;
        x_end := x_start + count * main_font.mono_width;
        // XXX: adjust start after computing end!
        x_start = max(x_start, xx left(parent_rect));
        x_end = min(x_end, xx right(parent_rect));

        if mouse.x >= x_start && mouse.x <= x_end {
            w := x_end - x_start;
            draw_hollow_axis_aligned_rectangle(xx x_start, xx origin.y, xx w, xx main_font.line_height, 2, color_gray);

            if handle_click && is_click(.MOUSE_BUTTON_RIGHT) {
                log_info_open_popup_menu(info, mouse, line_index, type);
                return true;
            }
        }
    }

    if handle_click && is_click(.MOUSE_BUTTON_RIGHT) {
        line_open_popup_menu(info, mouse, line_index);
        return true;
    }

    return false;
}

draw_text_line_with_ansi_escape_codes :: (font_set: My_Dynamic_Font, text: string,
                                          n_columns_to_skip: int, max_characters: int,
                                          left: float, text_x_tweak: float,
                                          bottom: float, text_y_tweak: float,
                                          default_color: Vector4, codes: [] Escape_Code_Info,
                                          current_style: *Style, override_style: Style)
{
    current_invisible_before: u16 = 0;

    segments: [..] struct { start: u16; count: u16; invisible_before: u16; style: Style; };
    segments.allocator = temp;
    array_reserve(*segments, codes.count + 1);

    cursor := 0;
    for codes {
        assert(cursor < text.count);
        segment_length := it.start - cursor;
        if segment_length != 0 {
            array_add(*segments, .{xx cursor, xx segment_length, current_invisible_before, current_style.*});
        }
        current_invisible_before += it.count;
        cursor = it.start + it.count;
        evaluate_style_sequence(it.sequence, current_style, default_color);
    }
    assert(cursor <= text.count);
    array_add(*segments, .{xx cursor, xx (text.count - cursor), current_invisible_before, current_style.*});

    i := 0;
    while i < segments.count {
        it := *segments[i];
        visible_start := it.start - it.invisible_before;
        if visible_start + it.count <= n_columns_to_skip { i += 1; continue; }
        to_cut := n_columns_to_skip - visible_start;
        if to_cut < 0 { i += 1; continue; }

        it.start += xx to_cut;
        it.count -= xx to_cut;
        break;
    }

    if i >= segments.count return;

    line_height := font_set.line_height;
    character_width := font_set.mono_width;

    stop := n_columns_to_skip + max_characters;
    while i < segments.count {
        defer i += 1;
        it := segments[i];

        // truncate text to fit in screen
        visible_start := it.start - it.invisible_before;
        if visible_start >= stop break;
        visible_end := visible_start + it.count;
        to_cut := visible_end - stop;
        if to_cut > 0 then it.count -= xx to_cut;

        x := left + character_width * (visible_start - n_columns_to_skip) + text_x_tweak;

        // choose color
        fg_color := it.style.fg_color;
        if override_style.fg_color.w > 0 then fg_color = override_style.fg_color;
        bg_color := it.style.bg_color;
        if override_style.bg_color.w > 0 then bg_color = override_style.bg_color;
        if it.style.attributes & .INVERSE then inline swap(*fg_color, *bg_color);

        // draw background
        if bg_color.w > 0 {
            w := character_width * it.count;
            draw_axis_aligned_rectangle(xx x, xx bottom, xx w, xx line_height, bg_color);
        }

        font := font_for_attributes(font_set, it.style.attributes);

        // TODO: tabs handling (I fucking hate tabs!!!!)
        segment_text := slice(text, it.start, it.count);
        w_text := Simp.prepare_text(font, segment_text);
        // This fails for unicode!
        // assert(w_text == main_font.mono_width * line.count);

        Simp.draw_prepared_text(font, xx x, xx (bottom + text_y_tweak), fg_color);
    }
}

draw_search_match_border :: (parent_rect: Rectangle, font: My_Dynamic_Font, text_x_tweak: float, y: float, line_index: int, line_length: int, cursor: *int) {
    search_match: *Search_Match_Info = null;
    color := search_match_color;

    while cursor.* < search_results.matches.count {
        it := *search_results.matches[cursor.*];
        if it.line_index == line_index {
            search_match = it;
            cursor.* += 1;
            break;
        } else if it.line_index > line_index {
            break;
        }
        cursor.* += 1;
    }

    if !search_match return;

    border_width := 2.0;

    // @ROBUSTNESS this y_tweak is copy-pasted from anchors code
    y_tweak := -border_width;
    y_bottom := y + y_tweak;
    h := font.line_height + border_width;
    h23 := 2 * h / 5;

    while true {
        // @ROBUSTNESS this global variable `scroll_columns` access is kinda ass
        x_in_rect := font.mono_width * (search_match.offset_in_line - scroll_columns) + text_x_tweak - border_width;
        // @INCOMPLETE unicode not supported
        match_length: int = search_match.match_count;
        if match_length == U8_MAX then match_length = line_length - search_match.offset_in_line;
        w := match_length * font.mono_width + border_width * 2;

        if x_in_rect > xx parent_rect.width { // match to the right of the visible line piece
            p0 := Vector2.{xx right(parent_rect), y_bottom + h/2};
            p1 := p0 + .{-h23, -h23};
            p2 := p0 + .{-h23,  h23};
            draw_fat_line(p0, p1, border_width, color);
            draw_fat_line(p0, p2, border_width, color);
        } else if x_in_rect + w < 0 {         // match to the left of the visible line piece
            p0 := Vector2.{xx parent_rect.left, y_bottom + h/2};
            p1 := p0 + .{h23, -h23};
            p2 := p0 + .{h23,  h23};
            draw_fat_line(p0, p1, border_width, color);
            draw_fat_line(p0, p2, border_width, color);
        } else {                              // match visible
            x := parent_rect.left + x_in_rect;
            // @INCOMPLETE currently drawing outside `parent_rect` sometimes
            draw_hollow_axis_aligned_rectangle(xx x, xx y_bottom, xx w, xx h, border = 2, color);
        }

        if cursor.* >= search_results.matches.count break;

        it := *search_results.matches[cursor.*];
        if it.line_index != line_index break;

        assert(search_match != it);
        search_match = it;
        cursor.* += 1;
    }
}

screen_position_to_line_index :: (rect: Rectangle, y: float) -> s64 {
    if y > xx rect.top return -1;
    rect_bottom := rect.top - rect.height;
    if y < xx rect_bottom return -1;

    // Am I retarded?
    y_in_rect_from_top := rect.top - y;
    row_index := floor(scroll_rows + y_in_rect_from_top / main_font.line_height);
    return xx row_index;
}

//
// text buffer stuff
//

Log_Text_Buffer :: struct {
    all_text: string;
    line_infos: [..] Log_Line_Info;
    max_line_length: int;

    // string owned by `all_text`
    all_log_sources: [..] string;
    // string owned by `all_text`
    sources_to_pid: Table(string, s32);
    merged_log_sources: [..] Merge_Info;
    log_ranges_of_source: [..] Log_Range;

    all_pids: [..] s32;
    all_fiber_ids: [..] s32;

    // string owned by `all_text`
    all_thread_names: [..] string;
    // string owned by `all_text`
    all_fiber_names: [..] string;
    // string owned by `all_text`
    all_module_names: [..] string;
    // string owned by `all_text`
    all_source_locations: [..] string;

    all_log_levels: [..] u8;

    escape_code_infos: [..] Escape_Code_Info;

    // string owned by `all_text`
    all_words: Table(string, int);
    // string owned by `all_text`
    message_words: Table(string, int);

    skipped_based_on_timestamp: int;

    // undo history
    all_text_history: [..] string;
    current_position_in_history := 0;

    // async
    current_version: u64;
    request: Parsing_Request;

    parsing_in_progress: bool;
    parsing_state: string;
    parsing_cursor: s64;
}
the_text_buffer: Log_Text_Buffer;

quicksort_duration: float64;

reset_text_buffer :: (using buffer: *Log_Text_Buffer) {
    array_reset_keeping_memory(*line_infos);
    max_line_length = 0;

    // Close the popup menu, because it can have references to the old data
    the_popup_menu.flags &= ~.OPEN;

    array_reset_keeping_memory(*all_log_sources);
    array_reserve(*all_log_sources, SOURCE_ID_UNKNOWN);
    // keeps memory
    table_reset(*sources_to_pid);
    array_reset_keeping_memory(*merged_log_sources);
    array_reset_keeping_memory(*log_ranges_of_source);

    array_reset_keeping_memory(*all_thread_names);
    array_reset_keeping_memory(*all_fiber_names);
    array_reset_keeping_memory(*all_module_names);
    array_reset_keeping_memory(*all_source_locations);

    array_reset_keeping_memory(*all_pids);
    array_reset_keeping_memory(*all_fiber_ids);

    array_reset_keeping_memory(*escape_code_infos);

    // keeps memory
    table_reset(*all_words);
    // keeps memory
    table_reset(*message_words);
}

get_line :: (using buffer: *Log_Text_Buffer, line_index: int) -> string {
    if line_index == line_infos.count return "";
    start := line_infos[line_index].line_offset;
    end := ifx line_index + 1 < line_infos.count then line_infos[line_index + 1].line_offset
                                                 else all_text.count;
    if (end > start) && (all_text[end - 1] == #char "\n") then end -= 1;
    line := slice(all_text, start, end - start);
    return line;
}

//
// buffer mutations
//

update_buffer_text :: (buffer: *Log_Text_Buffer, _new_data: string) {
    if buffer.current_position_in_history < buffer.all_text_history.count - 1 {
        // Drop any buffers in redo queue
        for buffer.current_position_in_history + 1..buffer.all_text_history.count - 1 {
            free(buffer.all_text_history[it]);
        }
        buffer.all_text_history.count = buffer.current_position_in_history + 1;
    }

    new_data := _new_data;
    if contains(new_data, #char "\r") {
        // FIXME could also replace this in place...
        t := replace(new_data, "\r\n", "\n");
        free(new_data);
        new_data = t;
        replace_in_place(new_data, #char "\r", #char "\n");
    }

    array_add(*buffer.all_text_history, new_data);
    buffer.current_position_in_history = buffer.all_text_history.count - 1;
    buffer.all_text = buffer.all_text_history[buffer.current_position_in_history];
}

do_undo_or_redo :: (buffer: *Log_Text_Buffer, type: Parsing_Request.Type) {
    assert(type == .UNDO || type == .REDO, "%", type);

    changed := false;

    if type == .UNDO && buffer.current_position_in_history > 0 {
        buffer.current_position_in_history -= 1;
        changed = true;
    } else if type == .REDO && buffer.current_position_in_history < buffer.all_text_history.count - 1 {
        buffer.current_position_in_history += 1;
        changed = true;
    }

    if !changed {
        buffer.parsing_state = "done";
        atomic_swap(*buffer.parsing_in_progress, false);
        return;
    }

    buffer.all_text = buffer.all_text_history[buffer.current_position_in_history];

    Profile();
    // @INCOMPLETE skip_until not supported
    process_text_buffer_data(buffer);
    Profile("process_text_buffer_data");
}

load_text_buffer_data :: (buffer: *Log_Text_Buffer, _filenames: [] string = .[], from_clipboard := false, skip_until: Calendar_Time = .{}) {
    mark := get_temporary_storage_mark();
    defer set_temporary_storage_mark(mark);

    new_data: string;
    if from_clipboard {
        // FIXME: should probably wrap this and other places with a mutex lock...
        buffer.parsing_state = "reading from clipboard";

        log("reading text data from clipboard");
        new_data = os_clipboard_get_text();
    } else {
        buffer.parsing_state = "reading from file";

        filenames := _filenames;
        if !filenames {
            sample_file := tprint("%/sample_log.txt", assets_directory);
            filenames = .[sample_file];
        }

        buffer.skipped_based_on_timestamp = 0;
        new_data = load_data_from_files(buffer, filenames, skip_until);
    }

    update_buffer_text(buffer, new_data);

    Profile();
    process_text_buffer_data(buffer, skip_until);
    Profile("process_text_buffer_data");
}

get_log_filenames_from_paths :: (filepaths: [] string) -> [] string {
    filenames: [..] string;
    filenames.allocator = temp;

    add_file_based_on_extension :: (filenames: *[..] string, filepath: string) {
        _, name, ext := path_decomp(filepath);
        if !name || name[0] == "." {
            log_error("ignoring file path '%'", filepath);
            return;
        }

        if ext == "" || ext == "log" || ext == "txt" {
            array_add(filenames, filepath);
        } else {
            log_error("ignoring file path '%'", filepath);
        }
    }

    visitor :: (info: *File_Visit_Info, filenames: *[..] string) {
        add_file_based_on_extension(filenames, info.full_name);
    }

    for filepaths {
        ok := visit_files(it, recursive=true, *filenames, visitor);
        if !ok {
            add_file_based_on_extension(*filenames, it);
        }
    }

    return filenames;
}

load_data_from_files :: (buffer: *Log_Text_Buffer, filenames: [] string, skip_until: Calendar_Time) -> data: string {
    pre, post, mids := extract_unique_middles(filenames);
    if filenames.count > 1 {
        log("filenames: %1%2%3", pre, mids, post);
    }

    if filenames.count == 1 {
        filename := filenames[0];
        log("reading file '%'", filename);
        new_data, ok := read_entire_file(filename);
        assert(ok);
        return new_data;
    }

    buffer.parsing_state = "reading from files";

    files: [..] string;
    files.allocator = temp;
    array_reserve(*files, filenames.count);

    sources: [..] string;
    sources.allocator = temp;
    array_reserve(*sources, filenames.count);
    source_max_len := 0;

    for filenames {
        source := mids[it_index];
        log("reading file '%' (source: '%')", it, source);
        data, ok := read_entire_file(it);
        assert(ok);
        array_add(*files, data);

        source_max_len = max(source_max_len, source.count);
        array_add(*sources, source);
    }

    buffer.parsing_state = "preprocessing files";
    Line_To_Sort :: struct { timestamp: Calendar_Time; timestamp_streak: s64; line: string; source: string; };
    compare_line_to_sort :: (l: Line_To_Sort, r: Line_To_Sort) -> int {
        t := inline compare_calendar_time(l.timestamp, r.timestamp);
        if t != 0 return t;
        return l.timestamp_streak - r.timestamp_streak;
    }
    lines_to_sort: [..] Line_To_Sort;
    defer array_reset(*lines_to_sort);
    total_size := 0;

    info: Log_Line_Info;

    streak: s64 = 0;
    prev_timestamp: Calendar_Time;

    for file: files {
        tail := file;
        source := sources[it_index];

        // reset info for each file
        prev_timestamp = .{};
        info.timestamp = to_calendar(seconds_to_apollo(0));

        while tail {
            found:, line:, tail = split_from_left(tail, #char "\n");
            ok := parse_log_line(null, line, *info, mode=.ONLY_TIMESTAMP);

            if ok && info.timestamp < skip_until {
                buffer.skipped_based_on_timestamp += 1;
                continue;
            }

            if info.timestamp == prev_timestamp { streak += 1; } else { streak = 0; }
            prev_timestamp = info.timestamp;

            array_add(*lines_to_sort, .{info.timestamp, streak, line, source});
            total_size += line.count;
            // for one "\n" after each line
            total_size += 1;
            // +3 for ' | ' after the source
            total_size += source_max_len + 3;
        }
    }

    buffer.parsing_state = "sorting logs";
    t0 := seconds_since_init();
    quick_sort(lines_to_sort, compare_line_to_sort);
    quicksort_duration = seconds_since_init() - t0;
    log("quicksort_duration: %", quicksort_duration);

    new_data := alloc_string(total_size);

    buffer.parsing_state = "copying data";
    p := new_data.data;
    for lines_to_sort {
        write_to_pointer(*p, it.source);

        padding := source_max_len - it.source.count;
        for 1..padding write_to_pointer(*p, " ");

        write_to_pointer(*p, " | ");
        write_to_pointer(*p, it.line);
        write_to_pointer(*p, "\n");
    }
    assert(p == new_data.data + total_size);

    return new_data;
}

process_text_buffer_data :: (using buffer: *Log_Text_Buffer, skip_until: Calendar_Time = .{}) {
    // TODO: keeping history, undo/redo, etc.

    buffer.parsing_state = "preprocessing";

    reset_text_buffer(buffer);

    buffer.parsing_state = "parsing logs";

    // skip until requested timestamp
    tail := all_text;
    while tail {
        found:, line:, tail = split_from_left(tail, #char "\n");

        temp_info: Log_Line_Info;
        ok := parse_log_line(null, line, *temp_info, mode=.ONLY_TIMESTAMP);
        // ignore `ok`
        if temp_info.timestamp < skip_until {
            buffer.skipped_based_on_timestamp += 1;
            continue;
        }

        start := line.data - all_text.data;
        tail = advance(all_text, start);
        break;
    }

    if tail.count != all_text.count {
        copy := copy_string(tail);
        free(all_text);
        all_text = copy;
        tail = all_text;
    }

    line_index := 0;
    while tail {
        // if we get a new request, we should just bale on the current one
        if (line_index % 100) == 0 && (buffer.current_version != buffer.request.version) { return; }

        defer line_index += 1;
        found:, line:, tail = split_from_left(tail, #char "\n");
        info := array_add(*line_infos);
        info.line_offset = line.data - buffer.all_text.data;

        buffer.parsing_cursor = info.line_offset;

        max_line_length = max(max_line_length, line.count);

        ok := parse_log_line(buffer, line, info);

        if log_ranges_of_source.count == 0 || last(log_ranges_of_source).source_id != info.source_id {
            array_add(*log_ranges_of_source, .{ info.source_id, line_index });
        }

        // line_offset := line.data - buffer.all_text.data;
        info.escape_codes_start = xx escape_code_infos.count;
        parse_ansi_escape_codes(line, 0, *escape_code_infos);
        info.escape_codes_count = xx (escape_code_infos.count - info.escape_codes_start);

        if !ok continue;

    }

    buffer.parsing_cursor = buffer.all_text.count;
    buffer.parsing_state = "post processing";

    // Add a dummy range start at the end for convenience
    array_add(*log_ranges_of_source, .{ SOURCE_ID_UNKNOWN, line_index });

    for to, to_id: buffer.all_log_sources for from, from_id: buffer.all_log_sources {
        // if we get a new request, we should just bale on the current one
        if (line_index % 100) == 0 && (buffer.current_version != buffer.request.version) { return; }

        if to_id == from_id continue;
        to_pids := table_find_multiple(*sources_to_pid, to);
        from_pids := table_find_multiple(*sources_to_pid, from);
        for from_pid: from_pids for to_pid: to_pids {
            if from_pid != to_pid continue;
            if !ok_to_merge(merged_log_sources, from=xx from_id, to=xx to_id) continue;
            array_add(*merged_log_sources, .{to=xx to_id, from=xx from_id});
            continue from;
        }
    }

    // line_index := 0;
    // while line_index < line_infos.count {
    //     defer line_index += 1000;
    //     array_add(*explicit_anchors, .{ line_index });
    // }

    log("line count: %", line_infos.count);
    log("max line length: %", max_line_length);
    log("escape code count: % (% unique)", escape_code_infos.count, escape_code_stats.count);
    log("unique word count: %", all_words.count);
    if all_words.count < 100 {
        for all_words {
            log("    %: %", it_index, it);
        }
    }
    log("skipped % based on timestamp %", skipped_based_on_timestamp, skip_until);

    // for escape_code_stats {
    //     log("'%': %, seen % times", cast(Ascii_Or_Hex) it_index, parse_escape_sequence(it_index), it);
    // }

    if search_results.matches {
        buffer.parsing_state = "updating search matches";
        update_search_results(buffer, search_results.search_string);
    }

    buffer.parsing_state = "done";
    atomic_swap(*buffer.parsing_in_progress, false);
}

remove_line_range :: (using buffer: *Log_Text_Buffer, first_line: s64, last_line: s64) {
    buffer.parsing_state = "removing lines";

    assert(0 <= first_line, "%", first_line);
    assert(first_line <= last_line, "% v %", first_line, last_line);
    assert(last_line <= line_infos.count, "% v %", last_line, line_infos.count);

    n_lines_removed := last_line - first_line + 1;
    for *explicit_anchors {
        if it.line_index < first_line continue;
        if it.line_index <= last_line {
            remove it;
        } else {
            it.line_index -= n_lines_removed;
        }
    }

    if scroll_rows > xx first_line {
        scroll_rows -= n_lines_removed;
        target_scroll_rows -= n_lines_removed;
    }

    start := line_infos[first_line].line_offset;
    // FIXME this should be a function
    end := ifx last_line >= line_infos.count - 1 then all_text.count
                                                 else line_infos[last_line + 1].line_offset;

    new_data := alloc_string(start + all_text.count - end);

    memcpy(new_data.data, all_text.data, start);
    memcpy(new_data.data + start, all_text.data + end, all_text.count - end);

    update_buffer_text(buffer, new_data);

    Profile();
    process_text_buffer_data(buffer);
    Profile("process_text_buffer_data");
}

//
// parsing thread
//

parsing_thread: Thread;
parsing_cond: Condition_Variable;
parsing_mutex_for_cond: Mutex;

safe_to_read_buffer_data :: (buffer: *Log_Text_Buffer) -> bool {
    return !buffer.parsing_in_progress && buffer.request.version == buffer.current_version;
}

start_parsing_thread :: (buffer: *Log_Text_Buffer) {
    init(*parsing_mutex_for_cond, "mutex_for_waker");
    init(*parsing_cond, "waker");
    init(*the_text_buffer.request.mutex, "request");

    parsing_thread.data = *the_text_buffer;
    thread_init(*parsing_thread, parsing_thread_proc);
    thread_start(*parsing_thread);
}

Parsing_Request :: struct {
    version: u64;

    Type :: enum { LOAD_FILE; LOAD_CLIPBOARD; REMOVE_LINE_RANGE; UNDO; REDO; };
    type: Type;

    filenames: [..] string;       // for .LOAD_FILE
    remove_line_first: s64; // for .REMOVE_LINE_RANGE
    remove_line_last: s64;  // for .REMOVE_LINE_RANGE
    skip_until: Calendar_Time; // for .LOAD_FILE

    mutex: Mutex;
}

copy_request :: (request: *Parsing_Request) -> Parsing_Request {
    using copy: Parsing_Request;
    version = request.version;
    type = request.type;
    remove_line_first = request.remove_line_first;
    remove_line_last = request.remove_line_last;
    skip_until = request.skip_until;

    array_reserve(*filenames, request.filenames.count);
    for request.filenames array_add(*filenames, copy_string(it));

    return copy;
}

set_filenames :: (request: *Parsing_Request, filenames: [] string) {
    for request.filenames free(it);
    request.filenames.count = 0;
    for filenames {
        if it array_add(*request.filenames, copy_string(it));
    }
}

parsing_thread_proc :: (thread: *Thread) -> s64 {
    context.thread_name = "parsing";
    buffer := cast(*Log_Text_Buffer, thread.data);

    while true {
        lock(*buffer.request.mutex);
        request := copy_request(*buffer.request,, temp);
        unlock(*buffer.request.mutex);

        if !buffer.parsing_in_progress && buffer.current_version == request.version {
            // wait until woken up
            wait(*parsing_cond, *parsing_mutex_for_cond);
            continue;
        }

        log("parsing request: %", request);

        atomic_swap(*buffer.parsing_in_progress, true);
        buffer.parsing_cursor = 0;
        buffer.current_version = request.version;

        if #complete request.type == {
        case .LOAD_FILE; #through;
        case .LOAD_CLIPBOARD;
            load_text_buffer_data(buffer, request.filenames, request.type == .LOAD_CLIPBOARD, request.skip_until);
        case .REMOVE_LINE_RANGE;
            remove_line_range(buffer, request.remove_line_first, request.remove_line_last);

        case .UNDO; #through;
        case .REDO;
            do_undo_or_redo(buffer, request.type);
        }

        reset_temporary_storage();
    }

    return 0;
}

request_load_text_buffer_data :: (buffer: *Log_Text_Buffer, filenames: [] string = .[], from_clipboard := false, skip_until: Calendar_Time = .{}) {
    goto_definition_helper :: load_text_buffer_data;
    lock(*buffer.request.mutex);
    defer unlock(*buffer.request.mutex);

    buffer.request.version += 1;
    buffer.request.type = ifx from_clipboard then .LOAD_CLIPBOARD else .LOAD_FILE;
    set_filenames(*buffer.request, filenames);
    buffer.request.skip_until = skip_until;

    wake(*parsing_cond);
}

request_remove_line_range :: (using buffer: *Log_Text_Buffer, first_line: s64, last_line: s64) {
    goto_definition_helper :: remove_line_range;
    lock(*buffer.request.mutex);
    defer unlock(*buffer.request.mutex);

    buffer.request.version += 1;
    buffer.request.type = .REMOVE_LINE_RANGE;
    buffer.request.remove_line_first = first_line;
    buffer.request.remove_line_last = last_line;

    wake(*parsing_cond);
}

request_buffer_text_undo :: (using buffer: *Log_Text_Buffer) {
    goto_definition_helper :: do_undo_or_redo;

    lock(*buffer.request.mutex);
    defer unlock(*buffer.request.mutex);

    buffer.request.version += 1;
    buffer.request.type = .UNDO;

    wake(*parsing_cond);
}

request_buffer_text_redo :: (using buffer: *Log_Text_Buffer) {
    goto_definition_helper :: do_undo_or_redo;

    lock(*buffer.request.mutex);
    defer unlock(*buffer.request.mutex);

    buffer.request.version += 1;
    buffer.request.type = .REDO;

    wake(*parsing_cond);
}

//
// log line info stuff
//

// TODO split this struct into 2: one with common info and one with extra info
Log_Line_Info :: struct {
    line_offset: s64;
    timestamp: Calendar_Time;
    pid: s32 = -1;
    fiber_id: s16 = -1;
    fiber_name_offset: s16 = -1;

    escape_codes_start: s16;
    escape_codes_count: s16;

    source_id: u8 = SOURCE_ID_UNKNOWN;
    thread_name_offset: u8 = THREAD_NAME_UNKNOWN;
    module_name_offset: u8 = MODULE_NAME_UNKNOWN;
    log_level: u8 = 0;

    location_offset: s16 = -1;

    timestamp_start: u8;
    timestamp_count: u8;
    source_start: u8;
    source_count: u8;
    pid_start: u8;
    pid_count: u8;
    thread_name_start: u8;
    thread_name_count: u8;
    fiber_id_start: u8;
    fiber_id_count: u8;
    fiber_name_start: u8;
    fiber_name_count: u8;
    module_name_start: u8;
    module_name_count: u8;
    location_start: u8;
    location_count: u8;
    log_level_start: u8;
    message_start: u8;
}

THREAD_NAME_UNKNOWN :: 0xff;
MODULE_NAME_UNKNOWN :: 0xff;

Log_Info_Piece_Type :: enum {
    NONE;
    TIMESTAMP;
    SOURCE;
    PID;
    THREAD_NAME;
    FIBER_ID;
    FIBER_NAME;
    MODULE;
    SOURCE_LOCATION;
    LOG_LEVEL;
    MESSAGE;
}

log_info_type_to_name :: (struct { type: Log_Info_Piece_Type; name: string; }).[
    .{.NONE,            "whole_line"},
    .{.TIMESTAMP,       "timestamp"},
    .{.SOURCE,          "source"},
    .{.PID,             "pid"},
    .{.THREAD_NAME,     "thread_name"},
    .{.FIBER_ID,        "fiber_id"},
    .{.FIBER_NAME,      "fiber_name"},
    .{.MODULE,          "module"},
    .{.SOURCE_LOCATION, "source_location"},
    .{.LOG_LEVEL,       "log_level"},
    .{.MESSAGE,         "message"},
];
#assert log_info_type_to_name.count == type_info(Log_Info_Piece_Type).values.count;

get_all_entities_of_type :: (buffer: *Log_Text_Buffer, type: Log_Info_Piece_Type) -> [] string {
    if #complete type == {
        case .NONE;             return .[];
        case .TIMESTAMP;        return .[];
        case .SOURCE;           return buffer.all_log_sources;
        case .PID;
            result: [..] string;
            array_reserve(*result, buffer.all_pids.count,, temp);
            for buffer.all_pids array_add(*result, tprint("%", it));
            return result;
        case .THREAD_NAME;      return buffer.all_thread_names;
        case .FIBER_ID;
            result: [..] string;
            array_reserve(*result, buffer.all_fiber_ids.count,, temp);
            for buffer.all_fiber_ids array_add(*result, tprint("%", it));
            return result;
        case .FIBER_NAME;       return buffer.all_fiber_names;
        case .MODULE;           return buffer.all_module_names;
        case .SOURCE_LOCATION;  return buffer.all_source_locations;
        case .LOG_LEVEL;
            result: [..] string;
            array_reserve(*result, buffer.all_log_levels.count,, temp);
            for buffer.all_log_levels {
                s := alloc_string(1,, temp);
                s[0] = it;
                array_add(*result, s);
            }
            return result;
        case .MESSAGE;
            result := resizable_array(string, buffer.message_words.count,, temp);
            for buffer.message_words {
                array_add(*result, it_index);
            }
            return result;
    }
}

lookup_log_info :: inline (buffer: *Log_Text_Buffer, line_index: int, type: Log_Info_Piece_Type) -> string, start: s16, count: u8 {
    info := *buffer.line_infos[line_index];
    value, start, count := lookup_log_info(buffer, info, type);
    if !value && count {
        line := get_line(buffer, line_index);
        value = slice(line, start, count);
    }
    return value, start, count;
}

lookup_log_info :: (buffer: *Log_Text_Buffer, info: *Log_Line_Info, type: Log_Info_Piece_Type) -> string, start: s16, count: u8 {
    if #complete type == {
        case .NONE;
            return "", 0, xx,no_check U8_MAX;
        case .TIMESTAMP;
            start := info.timestamp_start;
            count := info.timestamp_count;
            return "", start, count;
        case .SOURCE;
            start := info.source_start;
            count := info.source_count;
            return buffer.all_log_sources[info.source_id], start, count;
        case .THREAD_NAME;
            start := info.thread_name_start;
            count := info.thread_name_count;
            return buffer.all_thread_names[info.thread_name_offset], start, count;
        case .FIBER_NAME;
            start := info.fiber_name_start;
            count: = info.fiber_name_count;
            return buffer.all_fiber_names[info.fiber_name_offset], start, count;
        case .MODULE;
            start := info.module_name_start;
            count: = info.module_name_count;
            return buffer.all_module_names[info.module_name_offset], start, count;
        case .SOURCE_LOCATION;
            start := info.location_start;
            count: = info.location_count;
            return buffer.all_source_locations[info.location_offset], start, count;
        case .PID;
            start := info.pid_start;
            count := info.pid_count;
            return "", start, count;
        case .FIBER_ID;
            start := info.fiber_id_start;
            count := info.fiber_id_count;
            return "", start, count;
        case .LOG_LEVEL;
            start := info.log_level_start;
            count := 1;
            return "", start, xx,no_check count;
        case .MESSAGE;
            start := info.message_start;
            count := U8_MAX;
            return "", start, xx,no_check count;
    }

    log_error("entered unreachable code!");
    return "", 0, 0;
}

info_contains :: (info: *Log_Line_Info, piece: Log_Info_Piece_Type) -> bool {
    if #complete piece == {
        case .NONE;              return true;
        case .TIMESTAMP;         return info.timestamp_count != 0;
        case .SOURCE;            return info.source_id != SOURCE_ID_UNKNOWN;
        case .PID;               return info.pid != -1;
        case .THREAD_NAME;       return info.thread_name_offset != THREAD_NAME_UNKNOWN;
        case .FIBER_ID;          return info.fiber_id != -1;
        case .FIBER_NAME;        return info.fiber_name_offset != -1;
        case .MODULE;            return info.module_name_offset != MODULE_NAME_UNKNOWN;
        case .SOURCE_LOCATION;   return info.location_offset != -1;
        case .LOG_LEVEL;         return info.pid != -1;
        case .MESSAGE;           return info.message_start != 0;
    }
}

Parse_Log_Line_Mode :: enum { FULL; ONLY_TIMESTAMP; }
parse_log_line :: (buffer: *Log_Text_Buffer, line: string, info: *Log_Line_Info, $mode := Parse_Log_Line_Mode.FULL) -> bool {
    cursor := 0;

    #if mode == .FULL remember_words(line, *buffer.all_words);

    // skip whitespace
    while (cursor < line.count) && (inline is_space(line[cursor])) cursor += 1;
    if cursor >= line.count return false;

    first_non_whitespace := cursor;

    //
    // optional bullshit gitlab ci log prefix
    //
    timestamp, status, tail := parse_date_timestamp(advance(line, cursor));
    if status == .FULL
        && tail.count >= 8
        && tail[3] == #char "Z"
        && (inline is_digit(tail[0]))
        && (inline is_digit(tail[1]))
        && (inline is_digit(tail[2]))
        && (inline is_space(tail[4]))
        && (inline is_digit(tail[5]))
        && (inline is_digit(tail[6]))
        && (inline is_alpha(tail[7]))
    {
        cursor = tail.data - line.data + 8;

        // skip whitespace
        while (cursor < line.count) && (inline is_space(line[cursor])) cursor += 1;
        if cursor >= line.count return false;
    }

    //
    // parse source
    //
    // example: `default_2_3    |`
    //           ~~~~~~~~~~~
    //
    source_start := cursor;
    while cursor < line.count {
        c := line[cursor];
        if (inline is_space(c)) break;
        cursor += 1;
    }
    source: string;
    if cursor != source_start {
        source_count := cursor - source_start;
        source = slice(line, source_start, source_count);
    }

    // skip whitespace
    while (cursor < line.count) && (inline is_space(line[cursor])) cursor += 1;

    if cursor >= line.count return false;
    if line[cursor] == #char "|" {
        cursor += 1;
    } else {
        // it's not a source actually, reset back to start
        cursor = first_non_whitespace;
        source = "";
    }

    // skip whitespace
    while (cursor < line.count) && (inline is_space(line[cursor])) cursor += 1;

    //
    // optional syslog prefix
    //
    syslog_info:, ok:, tail = parse_syslog_prefix(advance(line, cursor));
    if ok {
        info.timestamp = syslog_info.timestamp;
        info.timestamp_start = xx (cursor + syslog_info.timestamp_start);
        info.timestamp_count = syslog_info.timestamp_count;

        cursor = ifx tail then tail.data - line.data else line.count;

        // skip whitespace
        while (cursor < line.count) && (inline is_space(line[cursor])) cursor += 1;
    }

    //
    // parse time stamp
    //

    timestamp_start := cursor;
    timestamp, status, tail = parse_date_timestamp(advance(line, cursor));
    if status != .FULL {
        #if mode == .ONLY_TIMESTAMP return false;

        source_is_not_number := false;
        for source if !inline is_digit(it) { source_is_not_number = true; break; }

        // @HACK I want to ingore lines like ` 123 |  let compilation = error;`
        // but keep lines which come from audit (why do I even bother?)
        if source_is_not_number {
            source_id := add_source(*buffer.all_log_sources, source);
            info.source_start = xx source_start;
            info.source_id = source_id;
        }

        // TODO: parse the json log format

        return false;
    }

    cursor = ifx tail then tail.data - line.data else line.count;

    info.timestamp = timestamp;
    info.timestamp_start = xx timestamp_start;
    info.timestamp_count = xx (cursor - timestamp_start);
    #if mode == .ONLY_TIMESTAMP return true;

    //
    // parse pid
    //

    // skip whitespace
    while (cursor < line.count) && (inline is_space(line[cursor])) cursor += 1;

    // `[`
    if line.count - cursor < 1 return false;
    lb := line[cursor]; cursor += 1;
    if lb != #char "[" return false;

    // pid
    pid_start := cursor;
    pid_count := 0;
    pid: s32;
    while cursor < line.count {
        d := line[cursor];
        if !inline is_digit(d) break;
        cursor += 1;
        pid_count += 1;
        pid = pid * 10 + (d - #char "0");
    }
    if cursor == pid_start return false;

    // `]`
    if line.count - cursor < 1 return false;
    rb := line[cursor]; cursor += 1;
    if rb != #char "]" return false;

    if !source {
        source_start = pid_start;
        source = slice(line, pid_start, pid_count);
    }
    source_id := add_source(*buffer.all_log_sources, source);
    info.source_start = xx source_start;
    info.source_count = xx source.count;
    info.source_id = source_id;

    info.pid = pid;
    info.pid_start = xx pid_start;
    info.pid_count = xx pid_count;

    array_add_if_unique(*buffer.all_pids, pid);

    already_seen := false;
    for table_find_multiple(*buffer.sources_to_pid, source) {
        if it == pid {
            already_seen = true;
            break;
        }
    }
    if !already_seen
        table_add(*buffer.sources_to_pid, source, pid);

    //
    // parse `$thread_name[/$fiber_id/$fiber_name/$module] [$file:$line]`
    //

    // skip whitespace
    while (cursor < line.count) && (inline is_space(line[cursor])) cursor += 1;

    // `$thread_name`
    thread_name_start := cursor;

    while (cursor < line.count) {
        if (line[cursor] == #char "/") break;
        if (line[cursor] == #char " ") break;
        cursor += 1;
    }
    if cursor == line.count return false;

    thread_name_end := cursor;

    if line[cursor] == #char "/" {
        cursor += 1;

        // Tarantool's human-readable log format is impossible to parse.
        // Here's a dumb heuristic

        // `$fiber_id`
        fiber_id: s16;
        fiber_id_start := cursor;
        while cursor < line.count {
            fiber_id_start = cursor;
            while (cursor < line.count) && (line[cursor] != #char "/") cursor += 1;
            if cursor == line.count return false;
            assert(line[cursor] == #char "/");

            text := slice(line, fiber_id_start, cursor - fiber_id_start);
            fiber_id = inline parse_positive_number(text, s16);
            if fiber_id != 0 break;

            thread_name_end = cursor;
            cursor += 1;
        }

        thread_name := slice(line, thread_name_start, thread_name_end - thread_name_start);
        thread_name_offset := add_thread_name(*buffer.all_thread_names, thread_name);
        info.thread_name_offset = thread_name_offset;
        info.thread_name_start = xx thread_name_start;
        info.thread_name_count = xx thread_name.count;

        assert(fiber_id != 0);
        info.fiber_id = fiber_id;
        info.fiber_id_start = xx fiber_id_start;
        info.fiber_id_count = xx (cursor - fiber_id_start);

        array_add_if_unique(*buffer.all_fiber_ids, fiber_id);

        assert(line[cursor] == #char "/"); cursor += 1;

        // `$fiber_name/[$module] [$file:$line]`
        fiber_name_start := cursor;
        while cursor + 2 < line.count {
            c0 := line[cursor];
            c1 := line[cursor + 1];
            c2 := line[cursor + 2];
            if c0 == #char " " && c2 == #char ">" && (c1 >= #char "A" && c1 <= #char "Z") break;
            cursor += 1;
        }

        fiber_name := slice(line, fiber_name_start, cursor - fiber_name_start);

        fiber_name=, module_name, location := parse_fiber_name_and_the_rest_of_the_garbage(fiber_name);
        fiber_name_offset := add_fiber_name(*buffer.all_fiber_names, fiber_name);
        info.fiber_name_offset = fiber_name_offset;
        info.fiber_name_start = xx fiber_name_start;
        info.fiber_name_count = xx fiber_name.count;

        if module_name {
            module_name_offset := add_module_name(*buffer.all_module_names, module_name);
            info.module_name_offset = module_name_offset;
            info.module_name_start = xx (module_name.data - line.data);
            info.module_name_count = xx module_name.count;
        }

        if location {
            location_offset := add_module_name(*buffer.all_source_locations, location);
            info.location_offset = location_offset;
            info.location_start = xx (location.data - line.data);
            info.location_count = xx location.count;
        }
    } else {
        thread_name := slice(line, thread_name_start, thread_name_end - thread_name_start);
        thread_name_offset := add_thread_name(*buffer.all_thread_names, thread_name);
        info.thread_name_offset = thread_name_offset;
        info.thread_name_start = xx thread_name_start;
        info.thread_name_count = xx thread_name.count;

        // skip whitespace
        while (cursor < line.count) && (inline is_space(line[cursor])) cursor += 1;

        start := cursor;

        // skip non whitespace
        while (cursor < line.count) && (!inline is_space(line[cursor])) cursor += 1;

        // `$file:$line`
        maybe_source_location := slice(line, start, cursor - start);
        ok := parse_source_location(maybe_source_location);
        if ok {
            location := maybe_source_location;
            location_offset := add_module_name(*buffer.all_source_locations, location);
            info.location_offset = location_offset;
            info.location_start = xx (location.data - line.data);
            info.location_count = xx location.count;
        } else {
            cursor = start;
        }
    }

    // skip whitespace
    while (cursor < line.count) && (inline is_space(line[cursor])) cursor += 1;

    //
    // log level: `L>`
    //
    if cursor + 2 >= line.count return false;
    if line[cursor + 1] != #char ">" return false;

    log_level := line[cursor];
    info.log_level = log_level;
    info.log_level_start = xx cursor;
    array_add_if_unique(*buffer.all_log_levels, log_level);

    cursor += 1; // `L`
    cursor += 1; // `>`

    // the rest is just the log message

    // skip whitespace
    while (cursor < line.count) && (inline is_space(line[cursor])) cursor += 1;

    info.message_start = xx cursor;

    remember_words(advance(line, cursor), *buffer.message_words);

    return true;
}

remember_words :: (text: string, all_words: *Table(string, int)) {
    mark := get_temporary_storage_mark();
    defer set_temporary_storage_mark(mark);

    new_words: [..] string;
    new_words.allocator = temp;

    cursor := 0;
    while cursor < text.count {
        // skip whitespace & punctuation
        while (cursor < text.count) && !(inline is_alnum(text[cursor])) { cursor += 1; }

        word_start := cursor;
        // find word end
        while (cursor < text.count) && (inline is_alnum(text[cursor])) { cursor += 1; }

        if word_start != cursor {
            word := slice(text, word_start, cursor - word_start);
            array_add(*new_words, word);
        }
    }

    for new_words {
        word := it;
        // has_alpha := false;
        // for word {
        //     if inline is_alpha(it) { has_alpha = true; break; }
        // }
        // if !has_alpha continue;

        find_or_add(all_words, word).* += 1;
    }
}

parse_fiber_name_and_the_rest_of_the_garbage :: (text: string) -> (fiber_name: string, module: string, location: string) {
    fiber_name := text;
    module := "";
    location := "";
    last_space := find_index_from_right(fiber_name, #char " ");
    if last_space != -1 {
        maybe_source_location := advance(fiber_name, last_space + 1);
        ok := parse_source_location(maybe_source_location);
        if ok {
            fiber_name.count = last_space;
            location = maybe_source_location;
        }
    }

    found:, fiber_name, module = split_from_left(fiber_name, #char "/");

    return fiber_name, module, location;
}

parse_source_location :: (input: string) -> (ok: bool, file: string, line: s32) {
    found, file, line_text := split_from_left(input, #char ":");
    if !found return false, "", -1;
    line := parse_positive_number(line_text, s32);
    if line == 0 return false, "", -1;

    return true, file, line;
}

parse_positive_number :: (text: string, $T: Type) -> T
#modify { return T == u8 || T == u16 || T == u32 || T == u64 || T == s8 || T == s16 || T == s32 || T == s64; }
{
    if !text return 0;

    result: T = 0;
    cursor := 0;
    while cursor < text.count {
        d := text[cursor]; cursor += 1;
        if !inline is_digit(d) return 0;
        result = result * 10 + (d - #char "0");
    }

    return result;
}

//
// log source stuff
//

Log_Range :: struct {
    source_id: u8;
    start_index: int;
}

SOURCE_ID_UNKNOWN :: cast(u8) 0xff;

log_source_color_scheme := Vector4.[
    color_coral,
    color_yellow,
    color_cyan,
    color_magenta,
    color_orange,
    color_baby_blue,
    color_purple,
    color_red,
    color_green,
    color_blue,
    color_white,
    color_brown,
];

get_log_source_color :: (source_id: u8) -> Vector4 {
    if source_id == SOURCE_ID_UNKNOWN return main_text_pane_text_color;

    for the_text_buffer.merged_log_sources if it.from == source_id return get_log_source_color(it.to);

    return log_source_color_scheme[source_id % log_source_color_scheme.count];
}

log_info_open_popup_menu :: (info: *Log_Line_Info, mouse: Vector2, line_index: int, type: Log_Info_Piece_Type) {
    data := Log_Line_Popup_Menu_Callback_Data.{line_index, type};
    menu := open_the_popup_menu(mouse, log_line_popup_menu_callback, data);

    using Log_Line_Popup_Menu_Item;
    popup_menu_push_item(menu, "Copy highlighted text to clipboard", id=xx COPY_TEXT);
    popup_menu_push_item(menu, "Copy line to clipboard", id=xx COPY_WHOLE_LINE);
    popup_menu_push_item(menu, "Add to search query", id=xx ADD_TO_SEARCH);

    if type == .SOURCE for log_source, source_id: the_text_buffer.all_log_sources {
        // Skip self
        if source_id == info.source_id continue;

        if !ok_to_merge(the_text_buffer.merged_log_sources, from=xx source_id, to=info.source_id) continue;

        color := get_log_source_color(xx source_id);
        pids := table_find_multiple(*the_text_buffer.sources_to_pid, log_source);
        item_id := xx MERGE_SOURCE + source_id;
        popup_menu_push_item(menu, "Merge with % (pid: %)", log_source, pids, id=item_id, icon=.{color, 8.0, .SQUARE});
    }
}

line_open_popup_menu :: (info: *Log_Line_Info, mouse: Vector2, line_index: int) {
    data := Log_Line_Popup_Menu_Callback_Data.{line_index, .NONE};
    menu := open_the_popup_menu(mouse, log_line_popup_menu_callback, data);

    using Log_Line_Popup_Menu_Item;
    popup_menu_push_item(menu, "Copy line to clipboard", id=xx COPY_WHOLE_LINE);
}

add_source :: (sources: *[..] string, source: string) -> source_id: u8 {
    for sources.* {
        if it == source return xx it_index;
    }

    if sources.count == SOURCE_ID_UNKNOWN return SOURCE_ID_UNKNOWN;

    array_add(sources, source);
    return xx (sources.count - 1);
}

add_thread_name :: (thread_names: *[..] string, thread_name: string) -> thread_name_offset: u8 {
    for thread_names.* {
        if it == thread_name return xx it_index;
    }

    if thread_names.count == THREAD_NAME_UNKNOWN return THREAD_NAME_UNKNOWN;

    array_add(thread_names, thread_name);
    return xx (thread_names.count - 1);
}

add_fiber_name :: (fiber_names: *[..] string, fiber_name: string) -> fiber_name_offset: s16 {
    for fiber_names.* {
        if it == fiber_name return xx it_index;
    }

    if fiber_names.count >= S16_MAX return -1;

    array_add(fiber_names, fiber_name);
    return xx (fiber_names.count - 1);
}

add_module_name :: (module_names: *[..] string, module_name: string) -> module_name_offset: u8 {
    for module_names.* {
        if it == module_name return xx it_index;
    }

    if module_names.count >= MODULE_NAME_UNKNOWN return MODULE_NAME_UNKNOWN;

    array_add(module_names, module_name);
    return xx (module_names.count - 1);
}

Merge_Info :: struct { from, to: u8; }

ok_to_merge :: (merges: [] Merge_Info, from: u8, to: u8) -> ok: bool {
    // Merging these 2 would lead to an infinite loop
    if detect_cycle(merges, from=from, to=to) return false;

    // Skip ones that are already merged somewhere, don't merge them to anything else
    for merge: merges if merge.from == from return false;

    return true;
}

detect_cycle :: (merges: [] Merge_Info, from: u8, to: u8) -> found_cycle: bool {
    for merges {
        if it.to != from continue;
        if it.from == to return true;
        if detect_cycle(merges, it.from, to) return true;
    }
    return false;
}

Log_Line_Popup_Menu_Callback_Data :: struct {
    line_index: int;
    type: Log_Info_Piece_Type;
}

Log_Line_Popup_Menu_Item :: enum {
    COPY_TEXT;
    COPY_WHOLE_LINE;
    ADD_TO_SEARCH;
    MERGE_SOURCE :: 0x100;
}

log_line_popup_menu_callback :: (menu: *Popup_Menu, event: Popup_Menu.Event) {
    assert(menu.callback_data.type == type_info(Log_Line_Popup_Menu_Callback_Data));
    using data := cast(*Log_Line_Popup_Menu_Callback_Data, menu.callback_data.value_pointer).*;

    buffer := *the_text_buffer;
    info := *buffer.line_infos[line_index];

    item_id := cast(Log_Line_Popup_Menu_Item) menu.items[menu.hovered_item].id;

    if event == .CLICK {
        if item_id == {

        case .COPY_TEXT;
            value := lookup_log_info(buffer, line_index, type);
            assert(xx value);
            os_clipboard_set_text(value);

        case .COPY_WHOLE_LINE;
            value := get_line(buffer, line_index);
            os_clipboard_set_text(value);

        case .ADD_TO_SEARCH;
            value := lookup_log_info(buffer, line_index, type);
            assert(xx value);

            type_name: string;
            for log_info_type_to_name {
                if it.type != type continue;
                type_name = it.name;
                break;
            }
            assert(xx type_name);

            text_input := *the_text_search_ui.text_input;
            if text_input.buffer && last(text_input.buffer) != #char " "
                text_input_append_text(text_input, " ");
            text_input_append_text(text_input, "$");
            text_input_append_text(text_input, type_name);
            text_input_append_text(text_input, "=");
            if contains_any_character(value, " \\\"") {
                text_input_append_text(text_input, to_string_literal(value,, temp));
            } else {
                text_input_append_text(text_input, value);
            }

            new_completions := update_search_results(buffer, xx text_input.buffer);
            save_completions(*the_text_search_ui, new_completions);
            open_text_search_ui();
        }
    }

    if type == .SOURCE {
        if event == .CLICK {
            if item_id >= .MERGE_SOURCE {
                id := cast(int) item_id - cast(int) Log_Line_Popup_Menu_Item.MERGE_SOURCE;
                this_source_id := info.source_id;
                array_add(*buffer.merged_log_sources, .{to=xx this_source_id, from=xx id});
                log("merged sources % and %", this_source_id, id);
            }
        }
    }
}

//
// text search stuff
//

Search_Results :: struct {
    search_string_storage: [MAX_SEARCH_STRING_LENGTH + 1] u8;
    search_string: string;
    matches: [..] Search_Match_Info;

    text_buffer: *Log_Text_Buffer;

    flags: enum_flags { CASE_INSENSITIVE; STRUCTURED_QUERY; }
}
MAX_SEARCH_STRING_LENGTH :: 255;

Search_Match_Info :: struct {
    line_index: s32;
    offset_in_line: s16;
    source_id: u8 = SOURCE_ID_UNKNOWN;
    match_count: u8;
}

search_match_color :: #run hex_color("f5a511");

search_results: Search_Results;

update_search_results :: (using buffer: *Log_Text_Buffer, _search_string: string) -> completions: Completions {
    search_string := _search_string;
    if search_string.count >= search_results.search_string_storage.count {
        search_string.count = search_results.search_string_storage.count;
        log_error("truncated search string to '%'", search_string);
    }
    memcpy(search_results.search_string_storage.data, search_string.data, search_string.count);
    search_results.search_string_storage[search_string.count] = 0; // XXX I don't really need this...
    search_results.search_string.data = search_results.search_string_storage.data;
    search_results.search_string.count = search_string.count;
    search_results.flags = 0;

    search_results.text_buffer = buffer;
    array_reset_keeping_memory(*search_results.matches);
    search_results.matches.allocator = context.default_allocator;
    search_results.flags = 0;

    if !search_string return .{};

    queries, do_query, completions := parse_search_string(search_string, buffer);

    search_string_lowercase := to_lower_copy(search_string,, temp);
    for search_string if is_alpha(it) { search_results.flags |= .CASE_INSENSITIVE; break; }

    if do_query {
        search_results.flags |= .STRUCTURED_QUERY;
        do_query_search(buffer, queries, *search_results.matches);
    } else {
        do_text_search(buffer, search_string_lowercase, *search_results.matches, xx (search_results.flags & .CASE_INSENSITIVE));
    }

    return completions;
}

do_text_search :: (buffer: *Log_Text_Buffer, search_string_lowercase: string, matches: *[..] Search_Match_Info, $$case_insensitive: bool) {
    next_range_cursor := 0;

    for line_index: 0..buffer.line_infos.count - 1 {
        line := get_line(buffer, line_index);
        if !line continue;

        offset := 0;
        if case_insensitive then offset = search_for_match_case_insensitive(line, search_string_lowercase);
                            else offset = search_for_match_case_sensitive(line, search_string_lowercase);

        source_id := SOURCE_ID_UNKNOWN;
        while next_range_cursor < buffer.log_ranges_of_source.count {
            if buffer.log_ranges_of_source[next_range_cursor].start_index > line_index break;
            next_range_cursor += 1;
        }
        assert(next_range_cursor > 0);
        range_info := buffer.log_ranges_of_source[next_range_cursor - 1];
        assert(range_info.start_index <= line_index);
        source_id = range_info.source_id;

        if offset >= 0 {
            assert(offset <= S16_MAX, "%", offset);
            array_add(matches, Search_Match_Info.{xx line_index, xx offset, source_id, xx search_string_lowercase.count});
        }
    }
}

Search_Query :: struct {
    match_any: [] Search_Query_Match_All;
}

Search_Query_Match_All :: struct {
    match_all: [] Search_Query_Leaf;
}

Search_Query_Leaf :: struct {
    type: Log_Info_Piece_Type;
    value: string;
}

do_query_search :: (buffer: *Log_Text_Buffer, queries: Search_Query, matches: *[..] Search_Match_Info) {
    line_matches := resizable_array(Search_Match_Info.[],, temp);
    for * line_info, line_index: buffer.line_infos {
        source_id := line_info.source_id;

        for match_any: queries.match_any {
            inline array_reset_keeping_memory(*line_matches);

            for query: match_any.match_all {
                if !info_contains(line_info, query.type) continue match_any;

                value, offset, count := inline lookup_log_info(buffer, line_index, query.type);
                assert(xx value);
                if query.value != "" {
                    index := inline find_index_from_left(value, query.value);
                    if index == -1 continue match_any;
                    offset += xx index;
                    count = xx query.value.count;
                }

                array_add(*line_matches, Search_Match_Info.{xx line_index, xx offset, source_id, count});
            }

            array_add(matches, ..line_matches);
        }
    }
}

parse_search_string :: (text: string, buffer: *Log_Text_Buffer = null) -> (Search_Query, ok: bool, completions: Completions) {
    match_any: [..] Search_Query_Match_All;
    match_any.allocator = temp;
    match_all: [..] Search_Query_Leaf;
    match_all.allocator = temp;
    completions: Completions;

    tail := text;
    tail = inline trim_left(tail);
    while tail {
        query, ok, completions=, cursor := parse_search_query_leaf(tail, buffer);
        if !ok {
            if match_all array_add(*match_any, .{match_all});
            return .{match_any}, false, completions;
        }

        array_add(*match_all, query);
        advance(*tail, cursor);
        tail = inline trim_left(tail);

        if tail && tail[0] == #char "|" {
            advance(*tail);
            tail = inline trim_left(tail);

            array_add(*match_any, .{array_copy(match_all,, temp)});
            array_reset_keeping_memory(*match_all);
        }
    }

    if match_all array_add(*match_any, .{match_all});

    return .{match_any}, true, completions;
}

// completions and possibly Search_Query_Leaf are allocated on temporary storage
parse_search_query_leaf :: (text: string, buffer: *Log_Text_Buffer = null) -> (Search_Query_Leaf, ok: bool, completions: Completions, cursor: int) {
    cursor := 0;

    completions: [..] string;
    completions.allocator = temp;

    // skip spaces
    while (cursor < text.count) && (inline is_space(text[cursor])) cursor += 1;
    if cursor == text.count return .{}, false, .{}, cursor;

    if text[cursor] != #char "$" {
        // simple text search, find completions for the last word

        last_word := "";

        // find last word
        while cursor < text.count {
            // skip spaces & punctuation
            while (cursor < text.count) && !(inline is_alnum(text[cursor])) cursor += 1;

            word_start := cursor;
            // skip word
            while (cursor < text.count) && (inline is_alnum(text[cursor])) cursor += 1;

            if word_start != cursor {
                last_word = slice(text, word_start, cursor - word_start);
            }
        }

        // find completions
        inline array_reset_keeping_memory(*completions);
        for buffer.all_words {
            // TODO to_lower_copy?
            if !starts_with(it_index, last_word) continue;

            array_add(*completions, it_index,, temp);
        }

        return .{}, false, .{completions, last_word.count}, cursor;
    }
    cursor += 1;

    type_start := cursor;
    while cursor < text.count {
        c := text[cursor];
        if !inline is_alnum(c) break;
        cursor += 1;
    }

    result: Search_Query_Leaf;

    type_string := slice(text, type_start, cursor - type_start);
    match := false;
    for log_info_type_to_name {
        if it.name == type_string {
            result.type = it.type;
            match = true;
            break;
        }

        if starts_with(it.name, type_string) {
            array_add(*completions, it.name);
        }
    }

    if !match return .{}, false, .{completions, type_string.count}, cursor;

    // skip spaces
    while (cursor < text.count) && (inline is_space(text[cursor])) cursor += 1;

    all_values := ifx buffer then get_all_entities_of_type(buffer, result.type);

    if cursor == text.count return result, true, .{all_values, 0}, cursor;

    if text[cursor] != #char "=" return .{}, false, .{}, cursor;
    cursor += 1;

    // skip spaces
    while (cursor < text.count) && (inline is_space(text[cursor])) cursor += 1;

    // nothing after =, complete every possible entity
    if cursor == text.count {
        return result, true, .{all_values, 0}, cursor;
    }

    if text[cursor] == #char "\"" {
        value, ok, cursor_offset := parse_string_literal(advance(text, cursor),, temp);
        cursor += cursor_offset;
        if !ok return .{}, false, .{}, cursor;
        result.value = value;
    } else {
        value_start := cursor;
        // skip until space
        while (cursor < text.count) && (!inline is_space(text[cursor])) cursor += 1;
        assert(cursor != value_start);

        result.value = slice(text, value_start, cursor - value_start);

        array_reset_keeping_memory(*completions);
        for all_values {
            if !starts_with(it, result.value) continue;

            array_add(*completions, it,, temp);
        }
    }

    return result, true, .{completions, result.value.count}, cursor;
}

// result allocated with context.allocator
parse_string_literal :: (input: string) -> (result: string, ok: bool, read_cursor: int) {
    read_cursor := 0;
    if input[read_cursor] != #char "\"" return "", false, 0;
    read_cursor += 1;

    result: string;
    result.data = alloc(input.count);
    result.count = input.count;
    write_cursor := 0;

    success := false;
    defer if !success free(result);

    while read_cursor < input.count {
        c := input[read_cursor]; read_cursor += 1;

        if c == #char "\"" { success = true; break; }

        if c != #char "\\" {
            result[write_cursor] = c; write_cursor += 1; continue;
        }
        c = input[read_cursor]; read_cursor += 1;

        if c == #char "\\" || c == #char "\"" {
            result[write_cursor] = c; write_cursor += 1; continue;
        }

        if c == {
            case #char "e"; result[write_cursor] = #char "\e"; write_cursor += 1; continue;
            case #char "n"; result[write_cursor] = #char "\n"; write_cursor += 1; continue;
            case #char "r"; result[write_cursor] = #char "\r"; write_cursor += 1; continue;
            case #char "t"; result[write_cursor] = #char "\t"; write_cursor += 1; continue;
        }

        if c == #char "x" {
            if read_cursor > input.count - 2 { return "", false, 0; }
            l := input[read_cursor]; read_cursor += 1;
            h := input[read_cursor]; read_cursor += 1;

            result[write_cursor] = l << 4 + h; write_cursor += 1; continue;
        }

    }

    result.count = write_cursor;
    return result, success, read_cursor;
}

to_string_literal :: (text: string) -> string {
    builder: String_Builder;
    builder.allocator = temp;
    append(*builder, #char "\"");
    print_ascii_or_hex(*builder, text);
    append(*builder, #char "\"");
    return builder_to_string(*builder);
}

search_for_match_case_sensitive :: (line: string, search_string: string, $max_offset: int = S16_MAX, $do_assert := false) -> s64 {
    first_char := search_string[0];
    i := find_index_from_left(line, first_char);

    if i < 0 || i >= max_offset return -1;

    match_start, match_length := i, 1;
    if match_length == search_string.count return match_start;

    line_length_clamped := min(line.count, max_offset + 1);

    i += 1;
    while i < line.count {
        if line[i] == search_string[match_length] {
            match_length += 1;
            if match_length == search_string.count return match_start;
            i += 1;
            continue;
        }

        match_length = 0;
        // XXX: overlapping matches are not supported!!!
        while (i < line_length_clamped) && (line[i] != search_string[match_length]) { i += 1; }
        if i >= line_length_clamped return -1;

        match_start, match_length = i, 1;
        i += 1;
    }

    return -1;
}

search_for_match_case_insensitive :: (line: string, search_string: string, $max_offset: int = S16_MAX, $do_assert := false) -> s64 {
    #if do_assert assert(is_lower(search_string));

    first_char_lower := search_string[0];
    i1 := inline find_index_from_left(line, first_char_lower);

    i2 := -1;
    if first_char_lower >= #char "a" && first_char_lower <= #char "z" {
        first_char_upper := inline to_upper(first_char_lower);
        i2 = inline find_index_from_left(line, first_char_upper);
    }

    i := 0;
    if i1 < 0 || i1 >= max_offset {
        if i2 < 0 || i2 >= max_offset return -1;   else i = i2;
    } else {
        if i2 < 0 || i2 >= max_offset then i = i1; else i = min(i1, i2);
    }

    match_start, match_length := i, 1;
    if match_length == search_string.count return match_start;

    line_length_clamped := min(line.count, max_offset + 1);

    i += 1;
    while i < line.count {
        char := line[i];
        if (inline to_lower(char)) == search_string[match_length] {
            match_length += 1;
            if match_length == search_string.count return match_start;
            i += 1;
            continue;
        }

        match_length = 0;
        // XXX: overlapping matches are not supported!!!
        while (i < line_length_clamped) && ((inline to_lower(line[i])) != search_string[match_length]) { i += 1; }
        if i >= line_length_clamped return -1;

        match_start, match_length = i, 1;
        i += 1;
    }

    return -1;
}

test_search_for_match :: () {
    line :: "aaabBbccCaAAadddAaAaAeEe";
    i: int;
    i = search_for_match_case_insensitive(line, "a",      do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_insensitive(line, "aa",     do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_insensitive(line, "aaa",    do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_insensitive(line, "aaaa",   do_assert=true); pretty_assert(i == 9);
    i = search_for_match_case_insensitive(line, "aaaaa",  do_assert=true); pretty_assert(i == 16);
    i = search_for_match_case_insensitive(line, "aaaaaa", do_assert=true); pretty_assert(i == -1);

    i = search_for_match_case_insensitive(line, "b",      do_assert=true); pretty_assert(i == 3);
    i = search_for_match_case_insensitive(line, "bb",     do_assert=true); pretty_assert(i == 3);
    i = search_for_match_case_insensitive(line, "bbb",    do_assert=true); pretty_assert(i == 3);

    i = search_for_match_case_insensitive(line, "c",      do_assert=true); pretty_assert(i == 6);
    i = search_for_match_case_insensitive(line, "cc",     do_assert=true); pretty_assert(i == 6);
    i = search_for_match_case_insensitive(line, "ccc",    do_assert=true); pretty_assert(i == 6);

    i = search_for_match_case_insensitive(line, "d",      do_assert=true); pretty_assert(i == 13);
    i = search_for_match_case_insensitive(line, "dd",     do_assert=true); pretty_assert(i == 13);
    i = search_for_match_case_insensitive(line, "ddd",    do_assert=true); pretty_assert(i == 13);

    i = search_for_match_case_insensitive(line, "e",      do_assert=true); pretty_assert(i == 21);
    i = search_for_match_case_insensitive(line, "ee",     do_assert=true); pretty_assert(i == 21);
    i = search_for_match_case_insensitive(line, "eee",    do_assert=true); pretty_assert(i == 21);

    i = search_for_match_case_sensitive(line, "a",      do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_sensitive(line, "A",      do_assert=true); pretty_assert(i == 10);
    i = search_for_match_case_sensitive(line, "aa",     do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_sensitive(line, "aA",     do_assert=true); pretty_assert(i == 9);
    i = search_for_match_case_sensitive(line, "Aa",     do_assert=true); pretty_assert(i == 11);
    i = search_for_match_case_sensitive(line, "AA",     do_assert=true); pretty_assert(i == 10);
    i = search_for_match_case_sensitive(line, "aaa",    do_assert=true); pretty_assert(i == 0);
    i = search_for_match_case_sensitive(line, "aaA",    do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "aAa",    do_assert=true); pretty_assert(i == 17);
    i = search_for_match_case_sensitive(line, "aAA",    do_assert=true); pretty_assert(i == 9);
    i = search_for_match_case_sensitive(line, "Aaa",    do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "AaA",    do_assert=true); pretty_assert(i == 16);
    i = search_for_match_case_sensitive(line, "AAa",    do_assert=true); pretty_assert(i == 10);
    i = search_for_match_case_sensitive(line, "AAA",    do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "aaaa",   do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "aAAa",   do_assert=true); pretty_assert(i == 9);
    i = search_for_match_case_sensitive(line, "AaAa",   do_assert=true); pretty_assert(i == 16);
    i = search_for_match_case_sensitive(line, "aAaA",   do_assert=true); pretty_assert(i == 17);
    i = search_for_match_case_sensitive(line, "AaaA",   do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "aaaaa",  do_assert=true); pretty_assert(i == -1);
    i = search_for_match_case_sensitive(line, "aaaaaa", do_assert=true); pretty_assert(i == -1);
}

a_to_A :: #char "A" - #char "a";
A_to_a :: #char "a" - #char "A";

other_case :: inline (char: u8) -> (char: u8, ok: bool) {
    if      (char >= #char "a") && (char <= #char "z") return char - A_to_a, true;
    else if (char >= #char "A") && (char <= #char "Z") return char + A_to_a, true;
    else return char, false;
}

//
// font stuff
//

My_Dynamic_Font :: struct {
    using regular: *Simp.Dynamic_Font;
    bold: *Simp.Dynamic_Font;
    italic: *Simp.Dynamic_Font;
    bold_italic: *Simp.Dynamic_Font;
    pixel_height: int;
    mono_width: int;
    line_height: int;
}

font_for_attributes :: (font: My_Dynamic_Font, attributes: Style_Attributes) -> *Simp.Dynamic_Font {
    if attributes == {
        case .BOLD;           return font.bold;
        case .ITALIC;         return font.italic;
        case .BOLD | .ITALIC; return font.bold_italic;
    }
    return font.regular;
}

reload_main_font :: () {
    load_font("Codetta", *main_font);
}

load_font :: (name: string, font: *My_Dynamic_Font) {
    assert(font.pixel_height >= 0);

    regular_name := tprint("%-Regular.ttf", name);
    log("loading '%' at size %", regular_name, font.pixel_height);
    font.regular = Simp.get_font_at_size(assets_directory, regular_name, font.pixel_height);

    bold_name := tprint("%-Bold.ttf", name);
    log("loading '%' at size %", bold_name, font.pixel_height);
    font.bold = Simp.get_font_at_size(assets_directory, bold_name, font.pixel_height);

    italic_name := tprint("%-Italic.ttf", name);
    log("loading '%' at size %", italic_name, font.pixel_height);
    font.italic = Simp.get_font_at_size(assets_directory, italic_name, font.pixel_height);

    bold_italic_name := tprint("%-BoldItalic.ttf", name);
    log("loading '%' at size %", bold_italic_name, font.pixel_height);
    font.bold_italic = Simp.get_font_at_size(assets_directory, bold_italic_name, font.pixel_height);

    font.line_height = xx (font.character_height - font.typical_descender);
    text_width := Simp.prepare_text(font.regular, "abc");
    font.mono_width = text_width / 3;
}

//
// text search ui
//

Text_Search_UI :: struct {
    rect: Rectangle;
    flags: enum_flags { OPEN; };

    text_input: Text_Input_State;
    text_input.max_length = MAX_SEARCH_STRING_LENGTH;

    // strings owned by `completions_storage`
    completions: Completions;
    completions_pool: Pool;
}
the_text_search_ui: Text_Search_UI;

text_search_ui_background_color :: ui_element_background_color;
text_search_ui_border_color     :: ui_element_border_color;
text_search_ui_cursor_color     :: ui_element_cursor_color;
text_search_ui_text_color       :: ui_element_text_color;
text_search_ui_border_width :: 3.0;

open_text_search_ui :: () {
    the_text_search_ui.flags |= .OPEN;
}

close_text_search_ui :: () {
    the_text_search_ui.flags &= ~.OPEN;
}

Completions :: struct {
    values: [] string;
    matched_prefix_length: int;
}

text_search_ui_handle_input_event :: (event: Input.Event) -> handled: bool {
    using the_text_search_ui;

    status := text_input_handle_event(*text_input, event, completions);
    if !status return false;

    if status & .TEXT_CHANGED {
        new_completions := update_search_results(*the_text_buffer, xx text_input.buffer);
        save_completions(*the_text_search_ui, new_completions);
    }

    if status & .ENTER_HIT {
        forwards := !(status & .SHIFT_PRESSED);
        jump_to_next_search_match(forwards);
    }

    if status & .CLOSED {
        close_text_search_ui();
    }

    request_redraw("text search ui update");

    return xx status;
}

save_completions :: (ui: *Text_Search_UI, new_completions: Completions) {
    if !ui.completions_pool.block_allocator.proc then set_allocators(*ui.completions_pool);

    reset(*ui.completions_pool);
    pool := Allocator.{pool_allocator_proc, *ui.completions_pool};

    ui.completions.matched_prefix_length = new_completions.matched_prefix_length;
    ui.completions.values = NewArray(new_completions.values.count, string,, pool);
    for new_completions.values {
        ui.completions.values[it_index] = copy_string(it,, pool);
    }
}

jump_to_next_search_match :: (forwards: bool) {
    effective_position := target_scroll_rows + jump_destination_row_offset();
    current_line_index := cast(int) floor(effective_position);
    if effective_position - xx current_line_index > 0 && forwards {
        current_line_index += 1;
    }

    // @ROBUSTNESS assuming search_matches are ordered
    matched_line_index := -1;
    if forwards {
        for search_results.matches {
            if it.line_index > current_line_index {
                matched_line_index = it.line_index;
                break;
            }
        }
    } else {
        for < search_results.matches {
            if it.line_index < current_line_index {
                matched_line_index = it.line_index;
                break;
            }
        }
    }

    if matched_line_index >= 0 {
        old_target_scroll_rows = target_scroll_rows;
        target_scroll_rows = matched_line_index - jump_destination_row_offset();
    }
}

do_text_search_ui :: (using ui: *Text_Search_UI, font: My_Dynamic_Font, mouse: Vector2, handle_mouse: bool, $do_draw: bool) -> mouse_handled: Mouse_Interaction {
    draw_axis_aligned_rectangle(rect, text_search_ui_background_color);
    draw_hollow_axis_aligned_rectangle(xx rect.left, xx bottom(rect), xx rect.width, xx rect.height,
                                       border = text_search_ui_border_width, text_search_ui_border_color);

    border_width := text_search_ui_border_width;
    text_x_tweak := border_width * 2 + 2;
    text_y_tweak := border_width * 2 + 2;
    text_x := rect.left + text_x_tweak;
    text_y := bottom(rect) + text_y_tweak;

    event_out: Mouse_Interaction;
    if axis_aligned_rectangle_contains(rect, mouse) {
        event_out |= .HOVER;
    }

    #if do_draw {
        click_handled := draw_text_input(*text_input, rect, text_x, text_y, font.regular, text_search_ui_text_color, handle_mouse);
        if click_handled then event_out |= .CLICK;
    }

    // do buttons
    if search_results.matches {
        fg_color := text_search_ui_text_color;
        bg_color := text_search_ui_background_color;

        size := cast(float) height(rect);
        pad := border_width;

        x := right(rect) + pad;
        y := cast(float) bottom(rect);

        handled := do_simple_button(x, y, size, size, border_width, Icon_Info.{fg_color, size * .6, .TRIANGLE_LEFT}, bg_color, mouse, handle_mouse, do_draw);
        if handled & .CLICK {
            jump_to_next_search_match(forwards=false);
        }
        event_out |= handled;

        x += size + pad;
        handled = do_simple_button(x, y, size, size, border_width, Icon_Info.{fg_color, size * .6, .TRIANGLE_RIGHT}, bg_color, mouse, handle_mouse, do_draw);
        if handled & .CLICK {
            jump_to_next_search_match(forwards=true);
        }
        event_out |= handled;
    }

    return event_out;
}

//
// anchor buttons
//

anchor_button_active_color  :: #run hex_color("4050d0");
anchor_button_hover_color   := #run hex_color("404040");
anchor_line_highlight_color := #run hex_color("404040");
explicit_anchors: [..] Anchor;
Anchor :: struct {
    line_index: s64;
    color := anchor_button_active_color;
    text := "";
    flags: enum_flags { TEXT_VISIBLE; }
}
make_anchor :: inline (line_index: int, color := anchor_button_active_color, text := "") -> Anchor {
    return .{line_index, color, text, 0};
}
hovered_anchor_button_line: s64 = -1;
active_anchor_segment: [2] Anchor;

get_anchor_at_line_index :: (line_index: int) -> anchor_index: int {
    for explicit_anchors if it.line_index == line_index return it_index;
    return -1;
}

anchor_button_toggle :: (line_index: int) {
    anchor_index := get_anchor_at_line_index(line_index);

    // FIXME: just use procedures which preserve order
    if anchor_index != -1 {
        free(explicit_anchors[anchor_index].text);
        array_unordered_remove_by_index(*explicit_anchors, anchor_index);
    } else {
        array_add(*explicit_anchors, make_anchor(line_index));
    }
    quick_sort(explicit_anchors, (l, r) => l.line_index - r.line_index);

    request_redraw("anchor button toggle");
}

get_or_add_anchor_button :: (line_index: int) -> anchor_index: int {
    anchor_index := get_anchor_at_line_index(line_index);
    if anchor_index != -1 return anchor_index;
    array_add(*explicit_anchors, make_anchor(line_index));
    quick_sort(explicit_anchors, (l, r) => l.line_index - r.line_index);
    return get_anchor_at_line_index(line_index);
}

anchor_button_open_popup_menu :: (line_index: int, mouse: Vector2) {
    anchor := make_anchor(-1);
    anchor_above := make_anchor(-1);   // I'm not stupid, this line is above
    anchor_bellow := make_anchor(-1);  // this one on the monitor
    for explicit_anchors {
        if it.line_index < line_index {
            anchor_above = it;
        } else if it.line_index > line_index {
            if anchor_bellow.line_index == -1 then anchor_bellow = it;
        } else {
            anchor = it;
        }
    }

    data := Anchor_Button_Popup_Menu_Callback_Data.{line_index, anchor, anchor_above, anchor_bellow};
    menu := open_the_popup_menu(mouse, anchor_button_popup_menu_callback, data);

    using Anchor_Button_Popup_Menu_Item_Id;
    active := (anchor.line_index != -1);
    if active then popup_menu_push_item(menu, "Remove anchor", id=xx TOGGLE);
              else popup_menu_push_item(menu, "Add anchor", id=xx TOGGLE);

    if active && anchor.text != "" then popup_menu_push_item(menu, "Edit text", id=xx EDIT_TEXT);
                                   else popup_menu_push_item(menu, "Set text", id=xx EDIT_TEXT);

    if active && anchor.text != "" {
        if anchor.flags & .TEXT_VISIBLE then popup_menu_push_item(menu, "Hide text", id=xx TOGGLE_TEXT_VISIBILITY);
                                        else popup_menu_push_item(menu, "Show text", id=xx TOGGLE_TEXT_VISIBILITY);
    }

    popup_menu_push_item(menu, "Delete 1 line", id=xx DELETE_1_LINE);

    if anchor_above.line_index != -1 then popup_menu_push_item(menu, "Delete lines up (to anchor)", id=xx DELETE_LINES_UP);
                                     else popup_menu_push_item(menu, "Delete lines up", id=xx DELETE_LINES_UP);

    if anchor_bellow.line_index != -1 then popup_menu_push_item(menu, "Delete lines down (to anchor)", id=xx DELETE_LINES_DOWN);
                                      else popup_menu_push_item(menu, "Delete lines down", id=xx DELETE_LINES_DOWN);

    request_redraw("popup menu opened");
}

Anchor_Button_Popup_Menu_Callback_Data :: struct {
    line_index: int;
    anchor: Anchor;
    anchor_above: Anchor;
    anchor_bellow: Anchor;
}

Anchor_Button_Popup_Menu_Item_Id :: enum {
    TOGGLE;
    EDIT_TEXT;
    TOGGLE_TEXT_VISIBILITY;
    DELETE_1_LINE;
    DELETE_LINES_UP;
    DELETE_LINES_DOWN;
}

anchor_button_popup_menu_callback :: (menu: *Popup_Menu, event: Popup_Menu.Event) {
    assert(menu.callback_data.type == type_info(Anchor_Button_Popup_Menu_Callback_Data));
    data := cast(*Anchor_Button_Popup_Menu_Callback_Data) menu.callback_data.value_pointer;

    first, last: Anchor;

    item := menu.items[menu.hovered_item];
    command := cast(Anchor_Button_Popup_Menu_Item_Id) item.id;
    if #complete command == {
        case .TOGGLE;
            if event == .CLICK
                anchor_button_toggle(data.line_index);

        case .EDIT_TEXT;
            if event == .CLICK {
                anchor_index := get_or_add_anchor_button(data.line_index);
                anchor := *explicit_anchors[anchor_index];
                source_id := the_text_buffer.line_infos[anchor.line_index].source_id;
                anchor.color = get_log_source_color(source_id);
                anchor.flags |= .TEXT_VISIBLE;
                x := left(scroll_bar_rect) - 16.0;
                total_line_count := the_text_buffer.line_infos.count;
                dy := height(scroll_bar_rect) / cast(float) total_line_count;
                y := top(scroll_bar_rect) - data.line_index * dy - calculate_height(*the_popup_text_input) / 2.0;
                // @LAME FIXME use a memory pool instead of New/free
                callback_data := New(int);
                callback_data.* = data.line_index;
                menu := open_the_popup_text_input(.{xx x, xx y}, .LEFT, anchor_button_text_update_callback, callback_data);
                set_text_buffer(menu, anchor.text);
            }

        case .TOGGLE_TEXT_VISIBILITY;
            if event == .CLICK {
                anchor_index := get_anchor_at_line_index(data.line_index);
                anchor := *explicit_anchors[anchor_index];
                if anchor.flags & .TEXT_VISIBLE then anchor.flags &= ~.TEXT_VISIBLE;
                                                else anchor.flags |=  .TEXT_VISIBLE;
            }

        case .DELETE_1_LINE;
            first = make_anchor(data.line_index);
            last = make_anchor(data.line_index);

        case .DELETE_LINES_UP;
            first = data.anchor_above;
            if first.line_index == -1 then first.line_index = 0;
            last = make_anchor(data.line_index);

        case .DELETE_LINES_DOWN;
            first = make_anchor(data.line_index);
            last = data.anchor_bellow;
            if last.line_index == -1 then last.line_index = the_text_buffer.line_infos.count - 1;
    }

    if command == .DELETE_1_LINE || command == .DELETE_LINES_UP || command == .DELETE_LINES_DOWN {
        active_anchor_segment[0] = first;
        active_anchor_segment[1] = last;

        if event == .CLICK {
            request_remove_line_range(*the_text_buffer, first.line_index, last.line_index);
            active_anchor_segment[0].line_index = -1;
            active_anchor_segment[1].line_index = -1;
        }
    }
}

//
// ui primitives
//

Popup_Menu :: struct {
    top: float;
    left: float;
    at: Vector2;
    items: [..] Popup_Menu_Item;
    hovered_item: s16 = -1;
    flags: enum_flags { OPEN; };

    callback: Callback;
    callback_data: Any;

    pool: Pool;
    allocator: Allocator;

    Callback :: #type (menu: *Popup_Menu, event: Event);
    Event :: enum { CLICK; HOVER; }
}

the_popup_menu: Popup_Menu;

Popup_Menu_Item :: struct {
    icon: Icon_Info;
    text: string;
    id: int;
}

Icon_Info :: struct {
    // TODO: support images
    color: Vector4;
    size: float;
    type: enum {
        NONE;
        SQUARE;
        TRIANGLE_LEFT;
        TRIANGLE_RIGHT;
        TRIANGLE_UP;
        TRIANGLE_DOWN;
    }
}

popup_menu_border_color :: text_search_ui_border_color;
popup_menu_border_width :: 2.0;
popup_menu_hovered_item_bg_color :: #run hex_color("505050");
popup_menu_item_bg_color :: text_search_ui_background_color;
popup_menu_item_text_color :: main_text_pane_text_color;

open_the_popup_menu :: inline (at: Vector2, callback: Popup_Menu.Callback) -> *Popup_Menu {
    return open_the_popup_menu(at, callback, null);
}

open_the_popup_menu :: (at: Vector2, callback: Popup_Menu.Callback, callback_data: $T) -> *Popup_Menu {
    menu := *the_popup_menu;
    array_reset(*menu.items);
    reset(*menu.pool);

    menu.callback = callback;
    info :: type_info(T);
    #if info.type == .POINTER || info.type == .STRING {
        menu.callback_data = callback_data;
    } else {
        menu.callback_data.type = info;
        menu.callback_data.value_pointer = get(*menu.pool, size_of(T));
        cast(*T, menu.callback_data.value_pointer).* = callback_data;
    }

    menu.at = at;
    menu.left = at.x;
    menu.top = at.y;
    menu.flags |= .OPEN;

    return menu;
}

popup_menu_push_item :: (menu: *Popup_Menu, format: string, args: .. Any, id := -1, icon := Icon_Info.{}) {
    text := sprint(format, ..args,, menu.allocator);
    array_add(*menu.items, Popup_Menu_Item.{text = text, id = id, icon = icon});
}

popup_menu_handle_click :: (menu: *Popup_Menu) {
    item := menu.hovered_item;

    if menu.callback {
        menu.callback(menu, .CLICK);
    }

    menu.flags &= ~.OPEN;
}

do_popup_menu :: (menu: *Popup_Menu, mouse: Vector2, handle_mouse: Mouse_Interaction, $do_draw := false) -> mouse_handled: Mouse_Interaction {
    if !menu.items {
        // Somebody opened an empty menu, just close it immediately
        menu.flags &= ~.OPEN;
        return 0;
    }

    font := ui_font;
    assert(menu.flags & .OPEN != 0);

    text_color := main_text_pane_text_color;

    h := font.line_height;
    text_y_tweak := -(font.typical_descender + font.max_descender) / 2;
    x_pad := text_y_tweak;
    text_x_tweak := h + x_pad;

    rect := rectangle_of(menu);

    //
    // draw background rect
    //
    #if do_draw {
        b := popup_menu_border_width;

        draw_axis_aligned_rectangle(rect, popup_menu_item_bg_color);
        draw_hollow_axis_aligned_rectangle(rect.left - b, bottom(rect) - b, rect.width + 2 * b, rect.height + 2 * b, b, popup_menu_border_color);
    }

    event_out: Mouse_Interaction;
    click := (handle_mouse & .CLICK) && is_click(.MOUSE_BUTTON_LEFT);

    // draw the text
    x := menu.left;
    y_top := menu.top;
    for menu.items {
        y_bottom := y_top - h;
        defer y_top = y_bottom;

        hover := false;
        if (handle_mouse & .HOVER) && (mouse.y >= y_bottom && mouse.y < y_top) {
            hover = true;
            menu.hovered_item = xx it_index;
            if click {
                popup_menu_handle_click(menu);
                event_out |= .CLICK;
            } else if menu.callback {
                menu.callback(menu, .HOVER);
            }
        }

        #if do_draw {
            if hover {
                draw_axis_aligned_rectangle(xx x, xx y_bottom, xx rect.width, xx h, popup_menu_hovered_item_bg_color);
            }

            draw_icon(x + h / 2.0, y_bottom + h / 2.0, it.icon);

            Simp.draw_text(font.regular, xx x + text_x_tweak, xx y_bottom + text_y_tweak, it.text, popup_menu_item_text_color);
        }
    }

    return event_out;
}

rectangle_of :: (menu: *Popup_Menu) -> Rectangle {
    font := ui_font;

    h := font.line_height;
    text_y_tweak := -(font.typical_descender + font.max_descender) / 2;
    x_pad := text_y_tweak;
    text_x_tweak := h + x_pad;

    text_w_max := 0;
    for menu.items {
        text_w := Simp.prepare_text(font.regular, it.text);
        text_w_max = max(text_w, text_w_max);
    }

    b := popup_menu_border_width;

    X := menu.left;
    H := h * menu.items.count;
    Y := menu.top - H + 1;
    W := text_w_max + text_x_tweak + x_pad;

    overflow := 0 - (Y - b);                if overflow > 0 { menu.top += overflow; Y += overflow; }
    overflow = (Y + H + b) - window_size.y; if overflow > 0 { menu.top -= overflow; Y -= overflow; }
    overflow = 0 - (X - b);                 if overflow > 0 { menu.left += overflow; X += overflow; }
    overflow = (X + W + b) - window_size.x; if overflow > 0 { menu.left -= overflow; X -= overflow; }

    rect: Rectangle;
    rect.left = xx X;
    rect.width = xx W;
    rect.height = xx H;
    rect.top = xx (Y + H);

    return rect;
}

Point_Relative_To :: enum {
    TOP_LEFT;
    MIDDLE_RIGHT;
    MIDDLE;
}

draw_simple_text_pane :: (parent_rect: Rectangle, font: *Simp.Dynamic_Font, point: Vector2, relative_to: Point_Relative_To, text: string, text_color: Vector4, background_color: Vector4) {
    if !text return;

    h := font.character_height;
    text_y_tweak := -(font.typical_descender + font.max_descender) / 2;
    x_pad := text_y_tweak;

    text_w_max := 0;
    line_count := 0;
    tail := text;
    while tail {
        found:, line:, tail = split_from_left(tail, #char "\n");
        line_count += 1;
        text_w := Simp.prepare_text(font, line);
        text_w_max = max(text_w, text_w_max);
    }

    H := h * line_count;
    x_left, y_top: float;
    if #complete relative_to == {
        case .TOP_LEFT;
            x_left = parent_rect.left + point.x;
            y_top = bottom(parent_rect) + point.y;
        case .MIDDLE_RIGHT;
            x_left = parent_rect.left + point.x - text_w_max;
            y_top = bottom(parent_rect) + H / 2 + point.y;
        case .MIDDLE;
            x_left = parent_rect.left + point.x - text_w_max / 2;
            y_top = bottom(parent_rect) + H / 2 + point.y;
    }

    // draw background rect
    {
        X := x_left - x_pad;
        Y := y_top - H + 1;
        W := text_w_max + x_pad * 2;
        draw_axis_aligned_rectangle(xx X, xx Y, xx W, xx H, background_color);
    }

    // draw the text
    y := y_top;
    tail = text;
    for 1..line_count {
        y -= h;
        found:, line:, tail = split_from_left(tail, #char "\n");
        Simp.draw_text(font, xx x_left, xx y + text_y_tweak, line, text_color);
    }
}

do_simple_button :: (x: float, y: float, w: float, h: float, border: float, icon: Icon_Info, bg_color: Vector4, mouse: Vector2, handle_mouse: bool, $do_draw: bool) -> handled: Mouse_Interaction {
    pad := border;

    fg_color_ := icon.color;
    bg_color_ := bg_color;

    event_out: Mouse_Interaction;
    if axis_aligned_rectangle_contains(x, y, w, h, mouse) {
        event_out |= .HOVER;

        swap(*fg_color_, *bg_color_);

        if handle_mouse && is_click(.MOUSE_BUTTON_LEFT) {
            event_out |= .CLICK;
        }
    }

    #if do_draw {
        draw_axis_aligned_rectangle(x, y, w, h, bg_color_);
        draw_hollow_axis_aligned_rectangle(x, y, w, h, border, text_search_ui_border_color);

        icon_ := icon;
        icon_.color = fg_color_;
        draw_icon(x + w / 2.0, y + h / 2.0, icon_);
    }

    return event_out;
}

draw_icon :: (x: float, y: float, icon: Icon_Info) {
    middle := Vector2.{x, y};
    if #complete icon.type == {
        case .NONE; return;
        case .SQUARE;
            w := icon.size;
            draw_axis_aligned_rectangle(x - w / 2.0, y - w / 2.0, w, w, icon.color);
        case .TRIANGLE_LEFT;
            size := icon.size;
            p0 := middle + .{-size * .4,          0};
            p1 := middle + .{ size * .4,  size * .5};
            p2 := middle + .{ size * .4, -size * .5};
            draw_triangle(p0, p1, p2, icon.color);

        case .TRIANGLE_RIGHT;
            size := icon.size;
            p0 := middle + .{ size * .4,          0};
            p1 := middle + .{-size * .4,  size * .5};
            p2 := middle + .{-size * .4, -size * .5};
            draw_triangle(p0, p1, p2, icon.color);

        case .TRIANGLE_UP;
            size := icon.size;
            p0 := middle + .{         0,  size * .4};
            p1 := middle + .{ size * .5, -size * .4};
            p2 := middle + .{-size * .5, -size * .4};
            draw_triangle(p0, p1, p2, icon.color);

        case .TRIANGLE_DOWN;
            size := icon.size;
            p0 := middle + .{         0, -size * .4};
            p1 := middle + .{ size * .5,  size * .4};
            p2 := middle + .{-size * .5,  size * .4};
            draw_triangle(p0, p1, p2, icon.color);

    }
}

Popup_Text_Input :: struct {
    #as using,except(flags) text_input: Text_Input_State;

    position: Vector2;
    minimum_width: float;
    height: float;
    direction: Adjust_Direction;
    flags: enum_flags { OPEN; };

    border_width :: 1.0;

    callback: Callback;
    callback_data: Any;

    Event :: enum { CHANGE; SUBMIT; }
    Callback :: #type (state: *Popup_Text_Input, event: Popup_Text_Input.Event);
}
the_popup_text_input := Popup_Text_Input.{
    text_input = Text_Input_State.{ max_length = 256 },
    minimum_width = 100.0,
};

Adjust_Direction :: enum { LEFT; RIGHT; }

rectangle_of :: (using state: *Popup_Text_Input) -> Rectangle {
    rect: Rectangle;
    rect.left = xx position.x;
    rect.width = xx minimum_width;
    rect.top = xx (position.y + height);
    rect.height = xx height;
    if direction == .LEFT then rect.left -= rect.width;
    return rect;
}

calculate_height :: (using state: *Popup_Text_Input) -> float {
    return 2 * state.border_width + xx (ui_font.character_height - ui_font.typical_descender);
}

open_the_popup_text_input :: inline (at: Vector2, direction: Adjust_Direction, callback: Popup_Text_Input.Callback) -> *Popup_Text_Input {
    return open_the_popup_text_input(at, direction, callback, null);
}

open_the_popup_text_input :: (at: Vector2, direction: Adjust_Direction, callback: Popup_Text_Input.Callback, callback_data: *$T) -> *Popup_Text_Input {
    state := *the_popup_text_input;

    state.callback = callback;
    state.callback_data.value_pointer = callback_data;
    state.callback_data.type = type_info(T);

    state.height = calculate_height(state);
    state.direction = direction;
    state.position = at;
    state.flags |= .OPEN;

    return state;
}

close_popup_text_input :: (state: *Popup_Text_Input) {
    state.flags &= ~.OPEN;
    free(state.callback_data.value_pointer);
    reset_text_input(*state.text_input);
}

set_text_buffer :: (state: *Popup_Text_Input, text: string) {
    array_reset_keeping_memory(*state.buffer);
    array_add(*state.buffer, .. cast([] u8) text);
    state.cursor = state.buffer.count;
}

anchor_button_text_update_callback :: (state: *Popup_Text_Input, event: Popup_Text_Input.Event) {
    line_index := downcast(int, state.callback_data).*;
    if event == .SUBMIT {
        anchor_index := get_anchor_at_line_index(line_index);
        assert(anchor_index != -1);
        anchor := *explicit_anchors[anchor_index];
        free(anchor.text);
        anchor.text = copy_string(xx state.buffer);
    }
}

downcast :: inline ($T: Type, any: Any) -> *T {
    assert(any.type == type_info(T), "%", any.type);
    return cast(*T) any.value_pointer;
}

popup_text_input_handle_input_event :: (using state: *Popup_Text_Input, event: Input.Event) -> handled: bool {
    status := text_input_handle_event(*state.text_input, event);
    if !status return false;

    if status & .TEXT_CHANGED {
        state.callback(state, .CHANGE);
    }

    if status & .ENTER_HIT {
        state.callback(state, .SUBMIT);
        close_popup_text_input(state);
    }

    if status & .CLOSED {
        close_popup_text_input(state);
    }

    request_redraw("popup text input");

    return xx status;
}

draw_popup_text_input :: (using state: *Popup_Text_Input, handle_click: bool) -> click_handled: bool {
    font := ui_font;
    rect := rectangle_of(state);
    draw_axis_aligned_rectangle(rect, text_search_ui_background_color);
    draw_hollow_axis_aligned_rectangle(xx rect.left, xx bottom(rect), xx rect.width, xx rect.height,
                                       border = text_search_ui_border_width, text_search_ui_border_color);

    text_x_tweak := border_width + 3;
    text_y_tweak := border_width + 4;
    text_x := rect.left + text_x_tweak;
    text_y := bottom(rect) + text_y_tweak;

    click_handled := draw_text_input(*state.text_input, rect, text_x, text_y, font.regular, text_search_ui_text_color, handle_click);
    return click_handled;
}

Text_Input_State :: struct {
    buffer: [..] u8;
    cursor: int;
    selection_start: int;

    flags: enum_flags {
        SELECTION_ACTIVE;
        SELECTION_DRAGGING;
        SELECTION_BY_WORD;
    };

    last_click_time := 0.0;
    double_click_period := 0.3;
    click_streak := 0;

    max_length: int = -1;
    // TODO: scroll
}

Text_Input_Status :: enum_flags {
    HANDLED;
    TEXT_CHANGED;
    ENTER_HIT;
    SHIFT_PRESSED;
    CLOSED;
}

reset_text_input :: (state: *Text_Input_State) {
    array_reset_keeping_memory(*state.buffer);
    state.cursor = 0;
    state.selection_start = 0;
    state.flags = 0;
    state.click_streak = 0;
}

text_input_handle_event :: (state: *Text_Input_State, event: Input.Event, completions := Completions.{}) -> result: Text_Input_Status {
    if !event.key_pressed return 0;
    if event.alt_pressed return 0;

    if !event.ctrl_pressed && event.key_code >= #char " " && event.key_code <= #char "~" {

        char := cast(u8) event.key_code;
        if event.shift_pressed {
            if char == {
                case #char "`";  char = #char "~";
                case #char "1";  char = #char "!";
                case #char "2";  char = #char "@";
                case #char "3";  char = #char "#";
                case #char "4";  char = #char "$";
                case #char "5";  char = #char "%";
                case #char "6";  char = #char "^";
                case #char "7";  char = #char "&";
                case #char "8";  char = #char "*";
                case #char "9";  char = #char "(";
                case #char "0";  char = #char ")";
                case #char "-";  char = #char "_";
                case #char "[";  char = #char "{";
                case #char "]";  char = #char "}";
                case #char "\\"; char = #char "|";
                case #char ";";  char = #char ":";
                case #char "'";  char = #char "\"";
                case #char ",";  char = #char "<";
                case #char ".";  char = #char ">";
                case #char "/";  char = #char "?";
            }
        } else {
            if char >= #char "A" && char <= #char "Z" {
                char += #char "a" - #char "A";
            } else if char == {
                // WTF is this???
                case #char "+"; char = #char "=";
            }
        }

        if state.flags & .SELECTION_ACTIVE text_input_delete_selection(state);

        if state.buffer.count + 1 > state.max_length {
            // TODO: error reporting
            log_error("text input truncated to % (wanted to add %)", state.max_length, 1);
            return .HANDLED;
        }

        inline text_input_insert_text_at_cursor(state, xx u8.[char]);

        return .TEXT_CHANGED;

    } else if event.key_code == {
        case .ESCAPE;
            state.flags &= ~.SELECTION_ACTIVE;
            return .CLOSED;

        case .BACKSPACE;
            if state.flags & .SELECTION_ACTIVE {
                text_input_delete_selection(state);
                return .TEXT_CHANGED;
            } else if state.cursor > 0 {
                delete_to := ifx event.ctrl_pressed then find_previous_word_start(xx state.buffer, state.cursor)
                                                    else state.cursor - 1;
                array_ordered_remove_range(*state.buffer, delete_to, state.cursor);
                state.cursor = delete_to;

                return .TEXT_CHANGED;
            }
            return .HANDLED;

        case .DELETE;
            if state.flags & .SELECTION_ACTIVE {
                text_input_delete_selection(state);
                return .TEXT_CHANGED;
            } else if state.cursor < state.buffer.count {
                delete_to := ifx event.ctrl_pressed then find_next_word_end(xx state.buffer, state.cursor)
                                                    else state.cursor + 1;
                array_ordered_remove_range(*state.buffer, state.cursor, delete_to);

                return .TEXT_CHANGED;
            }
            return .HANDLED;

        case .ARROW_LEFT;
            ended := text_input_update_selection_state_for_movement(state, event.shift_pressed);
            if ended {
                state.cursor = min(state.cursor, state.selection_start);
            } else if state.cursor > 0 {
                if event.ctrl_pressed then state.cursor = find_previous_word_start(xx state.buffer, state.cursor);
                                      else state.cursor -= 1;
            }
            return .HANDLED;

        case .ARROW_RIGHT;
            ended := text_input_update_selection_state_for_movement(state, event.shift_pressed);
            if ended {
                state.cursor = max(state.cursor, state.selection_start);
            } else if state.cursor < state.buffer.count {
                if event.ctrl_pressed then state.cursor = find_next_word_end(xx state.buffer, state.cursor);
                                      else state.cursor += 1;
            }
            return .HANDLED;

        case .ARROW_UP; // TODO: history
        case .ARROW_DOWN; // TODO: history

        case .HOME;
            text_input_update_selection_state_for_movement(state, event.shift_pressed);
            state.cursor = 0;
            return .HANDLED;

        case .END;
            text_input_update_selection_state_for_movement(state, event.shift_pressed);
            state.cursor = state.buffer.count;
            return .HANDLED;

        case xx #char "V";
            if event.ctrl_pressed {
                if state.flags & .SELECTION_ACTIVE text_input_delete_selection(state);
                text := os_clipboard_get_text(,, temp);
                if text {
                    // XXX ugly and stupid
                    text = replace(text, "\r\n", "",, temp);
                    text = replace(text, "\r", "",, temp);
                    text = replace(text, "\n", "",, temp);

                    if state.buffer.count + text.count > state.max_length {
                        // TODO: error reporting
                        log_error("text input truncated to % (wanted to add %)", state.max_length, text.count);
                        return .HANDLED;
                    }

                    inline text_input_insert_text_at_cursor(state, text);
                    return .TEXT_CHANGED;
                }
                return .HANDLED;
            }

        case xx #char "C";
            if event.ctrl_pressed && (state.flags & .SELECTION_ACTIVE) {
                start, end := min_max(state.selection_start, state.cursor);
                to_copy := array_view(state.buffer, start, end - start);
                os_clipboard_set_text(xx to_copy);

                return .HANDLED;
            }

        case xx #char "X";
            if event.ctrl_pressed && (state.flags & .SELECTION_ACTIVE) {
                start := min(state.selection_start, state.cursor);
                count := abs(state.selection_start - state.cursor);
                to_copy := array_view(state.buffer, start, count);
                os_clipboard_set_text(xx to_copy);
                text_input_delete_selection(state);

                return .HANDLED;
            }

        case xx #char "A";
            if event.ctrl_pressed {
                state.selection_start = 0;
                state.cursor = state.buffer.count;
                state.flags |= .SELECTION_ACTIVE;
                return .HANDLED;
            }

        case .TAB;
            if completions.values {
                to_skip := completions.matched_prefix_length;
                common_prefix := completions.values[0];
                for item: advance(completions.values, 1) {
                    if item.count < common_prefix.count {
                        common_prefix.count = item.count;
                    }
                    for common_prefix {
                        if it == item[it_index] continue;
                        common_prefix.count = it_index;
                        break;
                    }
                    if common_prefix.count <= to_skip break;
                }
                if common_prefix.count > to_skip {
                    to_append := advance(common_prefix, to_skip);
                    array_insert_at(*state.buffer, cast([] u8) to_append, state.cursor);
                    state.cursor += to_append.count;
                    return .TEXT_CHANGED;
                }
            }
            return .HANDLED;

        case .ENTER;
            if event.shift_pressed
                return .ENTER_HIT | .SHIFT_PRESSED;

            return .ENTER_HIT;
    }

    return 0;
}

text_input_get_text :: inline (state: *Text_Input_State) -> string {
    return xx state.buffer;
}

text_input_append_text :: (state: *Text_Input_State, text: string) {
    state.flags &= ~.SELECTION_ACTIVE;
    state.cursor = state.buffer.count;
    assert(state.buffer.allocator.proc == Default_Allocator.allocator_proc);
    inline text_input_insert_text_at_cursor(state, text);
}

text_input_insert_text_at_cursor :: (state: *Text_Input_State, text: string) {
    array_insert_at(*state.buffer, cast([] u8) text, state.cursor);
    state.cursor += text.count;
}

text_input_update_selection_state_for_movement :: inline (state: *Text_Input_State, shift_pressed: bool) -> selection_ended: bool {
    is_active := state.flags & .SELECTION_ACTIVE;
    if is_active && !shift_pressed {
        state.flags &= ~.SELECTION_ACTIVE;
        return true;
    }

    if !is_active && shift_pressed {
        state.flags |= .SELECTION_ACTIVE;
        state.selection_start = state.cursor;
    }

    return false;
}

text_input_delete_selection :: (state: *Text_Input_State) {
    state.flags &= ~.SELECTION_ACTIVE;
    if state.cursor == state.selection_start return;
    start := state.cursor;
    end := state.selection_start;
    if start > end then swap(*start, *end);
    array_ordered_remove_range(*state.buffer, start, end);
    state.cursor = start;
}

find_previous_word_start :: (text: string, cursor: int) -> start: int {
    start := cursor;
    // First find the previous word
    while start > 0 && inline is_space(text[start - 1]) {
        start -= 1;
    }

    if start == 0 return start;

    if inline is_word(text[start - 1]) {
        // Second find the word start
        while start > 0 && inline is_word(text[start - 1]) {
            start -= 1;
        }
    } else {
        // Second find the punctuation start
        while start > 0 && inline is_punctuation(text[start - 1]) {
            start -= 1;
        }
    }

    return start;
}

find_next_word_end :: (text: string, cursor: int) -> end: int {
    end := cursor;
    // First find the next word
    while end < text.count && inline is_space(text[end]) {
        end += 1;
    }

    if end == text.count return end;

    if inline is_word(text[end]) {
        // Second find the word end
        while end < text.count && inline is_word(text[end]) {
            end += 1;
        }
    } else {
        // Second find the punctuation end
        while end < text.count && inline is_punctuation(text[end]) {
            end += 1;
        }
    }

    return end;
}

find_word_around_cursor :: (text: string, cursor: int) -> (start: s32, count: s32) {
    start := cursor;
    // First find the previous word
    while start > 0 && inline is_space(text[start - 1]) {
        start -= 1;
    }

    if start == 0 return xx start, xx cursor;

    word_mode := inline is_word(text[start - 1]);

    count := 0;
    if word_mode {
        // Second find the word start
        while start > 0 && inline is_word(text[start - 1]) {
            start -= 1;
        }

        // Third find the word end
        while start + count < text.count && inline is_word(text[start + count]) {
            count += 1;
        }
    } else {
        // Second find the punctuation start
        while start > 0 && inline is_punctuation(text[start - 1]) {
            start -= 1;
        }

        // Third find the punctuation end
        while start + count < text.count && inline is_punctuation(text[start + count]) {
            count += 1;
        }
    }

    return xx start, xx count;
}

is_word :: (c: u8) -> bool {
    return inline is_alnum(c);
}

is_punctuation :: (c: u8) -> bool {
    return !(inline is_alnum(c)) && !(inline is_space(c));
}

text_input_update_click_streak :: (using state: *Text_Input_State) -> int {
    t := seconds_since_init();
    if t - last_click_time < double_click_period then click_streak += 1;
                                                 else click_streak = 1;
    last_click_time = xx t;
    return click_streak;
}

draw_text_input :: (state: *Text_Input_State, rect: Rectangle, x: float, y: float, font: *Simp.Dynamic_Font, fg_color: Vector4, handle_mouse: bool) -> click_handled: bool {
    // @INCOMPLETE TODO:
    // - scrolling
    // - mouse handling

    if (state.flags & .SELECTION_DRAGGING) && !is_down(.MOUSE_BUTTON_LEFT) {
        state.flags &= ~.SELECTION_DRAGGING & ~.SELECTION_BY_WORD;
    }

    cursor_y_tweak := -2.0;
    cursor_y := y + cursor_y_tweak;
    cursor_h := font.character_height;

    Simp.prepare_text(font, xx state.buffer);

    click_handled := false;
    mouse_in_rect := axis_aligned_rectangle_contains(rect, mouse);
    click := is_click(.MOUSE_BUTTON_LEFT);
    if handle_mouse && mouse_in_rect && ((state.flags & .SELECTION_DRAGGING) || click) {
        if click then text_input_update_click_streak(state);

        new_cursor := cursor_position_from_temporary_glyphs(rect, font.temporary_glyphs, x, mouse.x);

        if click && state.click_streak == 3 {
            state.selection_start = 0;
            state.cursor = state.buffer.count;
            state.flags |= .SELECTION_ACTIVE;
            state.flags &= ~.SELECTION_DRAGGING & ~.SELECTION_BY_WORD;
        } else if new_cursor != -1 {
            if click && state.click_streak == 2 {
                start, count := find_word_around_cursor(xx state.buffer, new_cursor);
                state.selection_start = start;
                state.cursor = start + count;
                state.flags |= (.SELECTION_DRAGGING | .SELECTION_ACTIVE | .SELECTION_BY_WORD);
            } else {
                if state.flags & .SELECTION_BY_WORD {
                    // FIXME: this is not working correctly. It should remember
                    // the position of the word where the selection started and
                    // when mouse moves the it should extend the selection only
                    // temporarily
                    start, count := find_word_around_cursor(xx state.buffer, new_cursor);
                    selection_start, selection_end := min_max(state.selection_start, state.cursor);
                    if start < selection_start {
                        state.selection_start = selection_end;
                        state.cursor = start;
                    } else if start + count > selection_end {
                        state.selection_start = selection_start;
                        state.cursor = start + count;
                    }
                } else {
                    state.cursor = new_cursor;
                }
                if !(state.flags & .SELECTION_DRAGGING) {
                    state.selection_start = new_cursor;
                    state.flags |= (.SELECTION_DRAGGING | .SELECTION_ACTIVE);
                }
            }
        }

        click_handled = true;
    }

    cursor_x := x;
    selection_start_x := x;
    for font.temporary_glyphs {
        if it_index < state.cursor          then cursor_x          += it.advance;
        if it_index < state.selection_start then selection_start_x += it.advance;
        if it_index >= state.cursor && it_index >= state.selection_start break;
    }

    if state.flags & .SELECTION_ACTIVE {
        start, end := min_max(selection_start_x, cursor_x);
        draw_axis_aligned_rectangle(start, cursor_y, end - start, xx cursor_h, color_orange);
    }

    Simp.draw_prepared_text(font, xx x, xx y, text_search_ui_text_color);

    {
        cursor_w := 2;

        draw_axis_aligned_rectangle(cursor_x, cursor_y, xx cursor_w, xx cursor_h, fg_color);
    }

    return click_handled;
}

cursor_position_from_temporary_glyphs :: (rect: Rectangle, temporary_glyphs: [] *Simp.Glyph_Data, text_x: float, mouse_x: float) -> cursor: int {
    prev_middle := cast(float) rect.left;
    curr_offset := text_x;
    for temporary_glyphs {
        curr_middle := curr_offset + it.advance / 2;
        if (mouse_x >= prev_middle) && (mouse_x <= curr_middle) {
            return it_index;
        }

        curr_offset += it.advance;
        prev_middle = curr_middle;
    }
    if (mouse_x >= prev_middle) && (mouse_x <= xx right(rect)) {
        return temporary_glyphs.count;
    }

    return -1;
}

//
// drawing
//

// Axis aligned rectangle
Rectangle :: struct {
    left: s32;
    // TODO: this should be bottom probably... maybe not though
    top: s32;
    width: s32;
    height: s32;
}

top    :: (rect: Rectangle) -> s32 #expand { return rect.top;               }
bottom :: (rect: Rectangle) -> s32 #expand { return rect.top - rect.height; }
left   :: (rect: Rectangle) -> s32 #expand { return rect.left;              }
right  :: (rect: Rectangle) -> s32 #expand { return rect.left + rect.width; }
width  :: (rect: Rectangle) -> s32 #expand { return rect.width;             }
height :: (rect: Rectangle) -> s32 #expand { return rect.height;            }

draw_axis_aligned_rectangle :: (p0: Vector2, p1: Vector2, color: Vector4) {
    Simp.immediate_quad(p0, .{ p0.x, p1.y }, p1, .{ p1.x, p0.y }, color, color, color, color);
}

draw_axis_aligned_rectangle :: (x: float, y: float, width: float, height: float, color: Vector4) {
    Simp.immediate_quad(.{ x        , y          },
                        .{ x        , y + height },
                        .{ x + width, y + height },
                        .{ x + width, y          },
                        color, color, color, color);
}

draw_axis_aligned_rectangle :: (rect: Rectangle, color: Vector4) {
    Simp.immediate_quad(.{ xx  rect.left              , xx (rect.top - rect.height) },
                        .{ xx  rect.left              , xx  rect.top                },
                        .{ xx (rect.left + rect.width), xx  rect.top                },
                        .{ xx (rect.left + rect.width), xx (rect.top - rect.height) },
                        color, color, color, color);
}

draw_hollow_axis_aligned_rectangle :: (x: float, y: float, width: float, height: float, border: float, color: Vector4) {
    draw_axis_aligned_rectangle(x, y, border, height, color);
    draw_axis_aligned_rectangle(x + border, y, width - 2 * border, border, color);
    draw_axis_aligned_rectangle(x + width - border, y, border, height, color);
    draw_axis_aligned_rectangle(x + border, y + height - border, width - 2 * border, border, color);
}

draw_fat_line :: (start: Vector2, end: Vector2, width: float32, color: Vector4) {
    direction := normalize(end - start);

    corner := Vector2.{ -(width / 2) * direction.y, (width / 2) * direction.x };

    top_l := end   - corner;
    top_r := end   + corner;
    bot_l := start - corner;
    bot_r := start + corner;

    Simp.immediate_quad(
        top_l, top_r, bot_r, bot_l,
        color, color, color, color,
    );
}

draw_triangle :: inline (p0: Vector2, p1: Vector2, p2: Vector2, color: Vector4) {
    Simp.immediate_triangle(.{ p0.x, p0.y, 1 }, .{ p1.x, p1.y, 1 }, .{ p2.x, p2.y, 1 }, color, color, color);
}

//
// math
//

axis_aligned_rectangle_contains :: inline (rect: Rectangle, point: Vector2) -> bool {
    return axis_aligned_rectangle_contains(xx rect.left, xx (rect.top - rect.height),
                                           xx rect.width, xx rect.height, point);
}

axis_aligned_rectangle_contains :: (left: float, bottom: float, width: float, height: float, point: Vector2) -> bool {
    if left > point.x            return false;
    if left + width < point.x    return false;
    if bottom > point.y          return false;
    if bottom + height < point.y return false;
    return true;
}

// source: https://stackoverflow.com/a/2049593
triangle_contains :: (p0: Vector2, p1: Vector2, p2: Vector2, target: Vector2) -> bool {
    sign :: (p0: Vector2, p1: Vector2, p2: Vector2) -> float #expand {
        return (p0.x - p2.x) * (p1.y - p2.y) - (p1.x - p2.x) * (p0.y - p2.y);
    }

    d0 := sign(target, p0, p1);
    d1 := sign(target, p1, p2);
    d2 := sign(target, p2, p0);

    has_neg := (d0 < 0) || (d1 < 0) || (d2 < 0);
    has_pos := (d0 > 0) || (d1 > 0) || (d2 > 0);

    return !(has_neg && has_pos);
}

triangle_contains :: inline (t: [3] Vector2, target: Vector2) -> bool {
    return triangle_contains(t[0], t[1], t[2], target);
}

//
// input
//

is_click :: (code: Input.Key_Code) -> bool #expand {
    return xx (Input.input_button_states[code] & .START);
}

is_down :: (code: Input.Key_Code) -> bool #expand {
    return xx (Input.input_button_states[code] & .DOWN);
}

is_down :: ($char: string) -> bool #expand {
    #assert char.count == 1;
    return xx (Input.input_button_states[char[0]] & .DOWN);
}

//
// command line arguments
//

input_file_full_paths: [..] string;
input_from_clipboard: bool;
run_tests_mode: bool;
skip_until_timestamp: Calendar_Time;

parse_command_line_arguments :: () {
    args := get_command_line_arguments();
    log("command line arguments: %", args);

    working_directory := get_working_directory();
    working_directory_path := parse_path(working_directory);

    cursor := 1;
    while cursor < args.count {
        arg := args[cursor];

        if arg == {
            case "-clipboard";
                input_from_clipboard = true;
                cursor += 1;
                continue;
            case "-run-tests";
                run_tests_mode = true;
                cursor += 1;
                continue;
            case "-since";
                cursor += 1;
                if cursor >= args.count {
                    log_error("expected a timestamp after '-since'");
                    exit(1);
                }
                to_parse := args[cursor];
                cursor += 1;
                timestamp, result := parse_date_timestamp(to_parse);
                if !result {
                    log_error("expected a timestamp after '-since', got '%'", to_parse);
                    exit(1);
                }
                skip_until_timestamp = timestamp;
                continue;
        }

        if arg[0] == #char "-" {
            log_error("unexpected option '%'", arg);
            exit(1);
        }

        break;
    }

    while cursor < args.count {
        file := args[cursor];
        if is_absolute_path(file) {
            array_add(*input_file_full_paths, file);
        } else if OS == .WINDOWS && file && file[0] == #char "/" {
            array_add(*input_file_full_paths, convert_wsl_path_to_windows(file));
        } else {
            array_add(*input_file_full_paths, sprint("%/%", working_directory, file));
        }
        cursor += 1;
    }

    if cursor != args.count {
        while cursor < args.count {
            arg := args[cursor];
            log_error("unexpected argument '%'", arg);
            cursor += 1;
        }
        exit(1);
    }

}

convert_wsl_path_to_windows :: (path: string) -> string {
    builder: String_Builder;
    builder.allocator = temp;

    tail := path;
    PREFIX :: "/mnt/";
    if starts_with(tail, PREFIX) && tail.count > PREFIX.count {
        append(*builder, to_upper(tail[PREFIX.count]));
        append(*builder, #char ":");

        tail = advance(tail, PREFIX.count + 1);
    }

    while tail {
        found:, head:, tail = split_from_left(tail, #char "/");
        append(*builder, head);
        if found then append(*builder, #char "\\");
    }

    return builder_to_string(*builder);
}


//
// ansi escape sequences
//

Escape_Code_Info :: struct {
    // relative to line start
    start: s32;
    count: u8;
    sequence: Small_Escape_Sequence;
}
#assert size_of(Escape_Code_Info) == 16;

escape_code_stats: Table(string, int);
escape_code_stats_pool: Pool;
escape_code_stats_allocator: Allocator;
parse_ansi_escape_codes :: (line: string, line_start: s32, infos: *[..] Escape_Code_Info) {
    tail := line;
    offset := 0;
    while tail {
        head:, found_escape:, tail = eat_visible_or_escape_sequence(tail);
        defer offset += head.count;

        if found_escape {
            sequence := parse_escape_sequence(head);
            start := cast(s32, line_start + offset);
            array_add(infos, Escape_Code_Info.{start, xx head.count, sequence});

            count := table_find_pointer(*escape_code_stats, head);
            if count then count.* += 1;
            else {
                table_add(*escape_code_stats, copy_string(head,, escape_code_stats_allocator), 1);
            }
        }
    }
}

// @INCOMPLETE lacking unicode support
eat_visible_or_escape_sequence :: (text: string) -> head: string, found_escape: bool, tail: string {
    if !text return "", false, "";

    count := find_index_from_left(text, #char "\e");
    if count < 0 then count = text.count;

    if count > 0 {
        // Visible character sequence
        head, tail := inline split_at(text, count);

        return head, false, tail;
    }

    // Escape sequence
    count += 1;

    if count < text.count {
        char := text[count];
        if char == #char "[" {
            count += 1;
            while count < text.count {
                char = text[count];
                count += 1;

                if char >= #char "a" && char <= #char "z" break;
                if char >= #char "A" && char <= #char "Z" break;
            }
        } else {
            // TODO: don't care about other escape codes for now
        }
    }

    head, tail := inline split_at(text, count);
    return head, true, tail;
}

Small_Escape_Sequence :: struct {
    command_letter: u8;
    argument_count: u8;
    arguments: [6] u8;
}
#assert size_of(Small_Escape_Sequence) == 8;

Ansi_Style_Command :: enum {
    RESET_ALL :: 0;

    BOLD_ON           :: 1;
    FAINT_ON          :: 2;
    ITALIC_ON         :: 3;
    UNDERLINE_ON      :: 4;
    BLINKING_ON       :: 5;
    INVERSE_ON        :: 7;
    HIDDEN_ON         :: 8;
    STRIKETHROUGH_ON  :: 9;

    BOLD_FAINT_OFF    :: 22;
    ITALIC_OFF        :: 23;
    UNDERLINE_OFF     :: 24;
    BLINKING_OFF      :: 25;
    INVERSE_OFF       :: 27;
    HIDDEN_OFF        :: 28;
    STRIKETHROUGH_OFF :: 29;

    FG_BLACK   :: 30;
    FG_RED     :: 31;
    FG_GREEN   :: 32;
    FG_YELLOW  :: 33;
    FG_BLUE    :: 34;
    FG_MAGENTA :: 35;
    FG_CYAN    :: 36;
    FG_WHITE   :: 37;

    FG_COLOR   :: 38;

    FG_DEFAULT :: 39;

    BG_BLACK   :: 40;
    BG_RED     :: 41;
    BG_GREEN   :: 42;
    BG_YELLOW  :: 43;
    BG_BLUE    :: 44;
    BG_MAGENTA :: 45;
    BG_CYAN    :: 46;
    BG_WHITE   :: 47;

    BG_COLOR   :: 48;

    BG_DEFAULT :: 49;

    FG_BRIGHT_BLACK   :: 90;
    FG_BRIGHT_RED     :: 91;
    FG_BRIGHT_GREEN   :: 92;
    FG_BRIGHT_YELLOW  :: 93;
    FG_BRIGHT_BLUE    :: 94;
    FG_BRIGHT_MAGENTA :: 95;
    FG_BRIGHT_CYAN    :: 96;
    FG_BRIGHT_WHITE   :: 97;

    BG_BRIGHT_BLACK   :: 100;
    BG_BRIGHT_RED     :: 101;
    BG_BRIGHT_GREEN   :: 102;
    BG_BRIGHT_YELLOW  :: 103;
    BG_BRIGHT_BLUE    :: 104;
    BG_BRIGHT_MAGENTA :: 105;
    BG_BRIGHT_CYAN    :: 106;
    BG_BRIGHT_WHITE   :: 107;
}

Style :: struct {
    fg_color: Vector4;
    bg_color: Vector4;
    attributes: Style_Attributes;
}

Style_Attributes :: enum_flags { BOLD; FAINT; ITALIC; UNDERLINE; BLINKING; INVERSE; HIDDEN; STRIKETHROUGH; };

print :: (builder: *String_Builder, sequence: Small_Escape_Sequence) {
    append(builder, sequence.command_letter);
    append(builder, "(");
    count := cast(int) sequence.argument_count;
    for 0..count - 2
        print(builder, "%, ", cast(Ansi_Style_Command) sequence.arguments[it]);
    if sequence.argument_count
        print(builder, "%", cast(Ansi_Style_Command) sequence.arguments[sequence.argument_count - 1]);
    append(builder, ")");
}

evaluate_style_sequence :: (using sequence: Small_Escape_Sequence, using style: *Style, fg_default := Vector4.{}, bg_default := Vector4.{}) {
    if command_letter != #char "m" return;

    i := 0;
    while i < argument_count {
        command := cast(Ansi_Style_Command) arguments[i];
        if command == {
            case .RESET_ALL;
                fg_color = fg_default;
                bg_color = bg_default;
                attributes = xx 0;
            case .BOLD_ON;          attributes |= .BOLD;
            case .FAINT_ON;         attributes |= .FAINT;
            case .ITALIC_ON;        attributes |= .ITALIC;
            case .UNDERLINE_ON;     attributes |= .UNDERLINE;
            case .BLINKING_ON;      attributes |= .BLINKING;
            case .INVERSE_ON;       attributes |= .INVERSE;
            case .HIDDEN_ON;        attributes |= .HIDDEN;
            case .STRIKETHROUGH_ON; attributes |= .STRIKETHROUGH;

            case .BOLD_FAINT_OFF;    attributes &= ~(.BOLD | .FAINT);
            case .ITALIC_OFF;        attributes &= ~.ITALIC;
            case .UNDERLINE_OFF;     attributes &= ~.UNDERLINE;
            case .BLINKING_OFF;      attributes &= ~.BLINKING;
            case .INVERSE_OFF;       attributes &= ~.INVERSE;
            case .HIDDEN_OFF;        attributes &= ~.HIDDEN;
            case .STRIKETHROUGH_OFF; attributes &= ~.STRIKETHROUGH;

            case .FG_BLACK;   fg_color = color_black;
            case .FG_RED;     fg_color = color_red;
            case .FG_GREEN;   fg_color = color_green;
            case .FG_YELLOW;  fg_color = color_yellow;
            case .FG_BLUE;    fg_color = color_blue;
            case .FG_MAGENTA; fg_color = color_magenta;
            case .FG_CYAN;    fg_color = color_cyan;
            case .FG_WHITE;   fg_color = color_white;
            case .FG_COLOR;   log_error("command 38 not implemented yet"); return;
                // TODO
                // - 2;{id}
                // - 5;{r};{g};{b}
            case .FG_DEFAULT; fg_color = fg_default;

            case .BG_BLACK;   bg_color = color_black;
            case .BG_RED;     bg_color = color_red;
            case .BG_GREEN;   bg_color = color_green;
            case .BG_YELLOW;  bg_color = color_yellow;
            case .BG_BLUE;    bg_color = color_blue;
            case .BG_MAGENTA; bg_color = color_magenta;
            case .BG_CYAN;    bg_color = color_cyan;
            case .BG_WHITE;   bg_color = color_white;
            case .BG_COLOR;   log_error_once("command 48 not implemented yet"); return;
                // TODO
                // - 2;{id}
                // - 5;{r};{g};{b}
            case .BG_DEFAULT; bg_color = fg_default;

            case .FG_BRIGHT_BLACK;   fg_color = color_gray;
            case .FG_BRIGHT_RED;     fg_color = color_red;     log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_GREEN;   fg_color = color_green;   log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_YELLOW;  fg_color = color_yellow;  log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_BLUE;    fg_color = color_blue;    log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_MAGENTA; fg_color = color_magenta; log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_CYAN;    fg_color = color_cyan;    log_error_once("bright colors not supported yet");
            case .FG_BRIGHT_WHITE;   fg_color = color_white;   log_error_once("bright colors not supported yet");

            case .BG_BRIGHT_BLACK;   bg_color = color_gray;
            case .BG_BRIGHT_RED;     bg_color = color_red;     log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_GREEN;   bg_color = color_green;   log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_YELLOW;  bg_color = color_yellow;  log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_BLUE;    bg_color = color_blue;    log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_MAGENTA; bg_color = color_magenta; log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_CYAN;    bg_color = color_cyan;    log_error_once("bright colors not supported yet");
            case .BG_BRIGHT_WHITE;   bg_color = color_white;   log_error_once("bright colors not supported yet");
            case; log_error("unknown command: %", command);
        }
        i += 1;
    }
}

source_code_location_equals :: (a: Source_Code_Location, b: Source_Code_Location) -> bool {
    return a.line_number == b.line_number && a.character_number == b.character_number &&
        a.fully_pathed_filename == b.fully_pathed_filename;
}
source_code_location_hash :: (loc: Source_Code_Location) -> u32 {
    h := Hash.get_hash(loc.fully_pathed_filename);
    h = Hash.get_hash(loc.line_number, h);
    h = Hash.get_hash(loc.character_number, h);
    return h;
}

log_error_once_seen_locations: Table(Source_Code_Location, bool, given_hash_function=source_code_location_hash, given_compare_function=source_code_location_equals);
log_error_once :: (format_string: string, args: .. Any, loc := #caller_location, flags := Log_Flags.NONE, user_flags : u32 = 0, section : *Log_Section = null) {
    seen, ok := table_find(*log_error_once_seen_locations, loc);
    if ok && seen return;

    table_add(*log_error_once_seen_locations, loc, true);
    inline log_error(format_string, ..args, loc=loc, flags=flags, user_flags=user_flags, section=section);
}

parse_escape_sequence :: (s: string) -> Small_Escape_Sequence, bool {
    if s.count < 3 return .{}, false;
    if s[0] != #char "\e" return .{}, false;
    if s[1] != #char "[" return .{}, false;

    result: Small_Escape_Sequence;
    cursor := 2;
    parsing_number := false;
    while cursor < s.count {
        c := s[cursor];
        if inline is_alpha(c) {
            if parsing_number then result.argument_count += 1;
            result.command_letter = c;
            break;
        } else if inline is_digit(c) {
            arg := *result.arguments[result.argument_count];
            arg.* = arg.* * 10 + c - #char "0";
            parsing_number = true;
        } else if c == #char ";" {
            if parsing_number {
                result.argument_count += 1;
                parsing_number = false;
            }
        }
        cursor += 1;
    }

    assert(result.command_letter != 0);
    return result, true;
}

//
// logging
//

#add_context thread_name: string;

my_logger :: (message: string, data: *void, info: Log_Info) {
    builder: String_Builder;
    builder.allocator = temp;

    if info.common_flags & .ERROR   print(*builder, "\e[31m");
    if info.common_flags & .WARNING print(*builder, "\e[33m");

    print_time_for_log(*builder, to_calendar(current_time_consensus(), .LOCAL));
    print(*builder, ": ");
    if #compile_time print(*builder, "#compile_time ");

    if context.thread_name && context.thread_name != "main" {
        append(*builder, context.thread_name);
        append(*builder, " ");
    }

    filename := path_filename(info.location.fully_pathed_filename);
    print(*builder, "[%:%] %\n", filename, info.location.line_number, message);

    if info.common_flags & (.ERROR | .WARNING) print(*builder, "\e[0m");

    write_builder(*builder);
}

print_pretty_duration :: (builder: *String_Builder, duration_in_seconds: float64) {
    whole_seconds := cast(int, duration_in_seconds);
    need_space := false;
    if whole_seconds > 3600 {
        hours := whole_seconds / 3600;
        print(builder, "%h", FormatInt.{value = hours});
        need_space = true;
    }

    if whole_seconds > 60 {
        minutes := (whole_seconds % 3600) / 60;
        if need_space append(builder, " ");
        print(builder, "%m", FormatInt.{value = minutes});
        need_space = true;
    }

    {
        seconds := whole_seconds % 60;
        milliseconds := cast(int, frac(duration_in_seconds) * 1000);
        if need_space append(builder, " ");
        print(builder, "%.%s", FormatInt.{value = seconds},
                               FormatInt.{value = milliseconds, minimum_digits = 3});
    }
}

print_time_for_log :: (builder: *String_Builder, date_time: Calendar_Time) {
    using date_time;
    print(builder, "%:%:%.%", FormatInt.{value = hour,        minimum_digits = 2},
                              FormatInt.{value = minute,      minimum_digits = 2},
                              FormatInt.{value = second,      minimum_digits = 2},
                              FormatInt.{value = millisecond, minimum_digits = 3});
}

print_date_time_for_log :: (builder: *String_Builder, date_time: Calendar_Time) {
    using date_time;
    print(builder, "%-%-% %:%:%.%", year,
                                    FormatInt.{value = month_starting_at_0 + 1,        minimum_digits = 2},
                                    FormatInt.{value = day_of_month_starting_at_0 + 1, minimum_digits = 2},
                                    FormatInt.{value = hour,                           minimum_digits = 2},
                                    FormatInt.{value = minute,                         minimum_digits = 2},
                                    FormatInt.{value = second,                         minimum_digits = 2},
                                    FormatInt.{value = millisecond,                    minimum_digits = 3});
}

//
// another attempt at struct printer
//

my_struct_printer :: (builder: *String_Builder, any: Any, struct_printer_data: *void) -> bool {
    printer := get_constant_member_printer(any.type);
    if printer != null {
        return printer(builder, any);
    }

    if any.type == type_info(Source_Code_Location) {
        print_source_code_location(builder, xx any.value_pointer);
        return true;
    } else if any.type == type_info(Ascii_Or_Hex) {
        print_ascii_or_hex(builder, xx cast(*Ascii_Or_Hex, any.value_pointer).*);
        return true;
    } else if any.type == type_info(Small_Escape_Sequence) {
        print(builder, cast(*Small_Escape_Sequence, any.value_pointer).*);
        return true;
    } else if any.type == type_info(*Type_Info) {
        print_type_to_builder(builder, cast(**Type_Info, any.value_pointer).*);
        return true;
    }

    return false;
}

Struct_Printer_Type :: #type (*String_Builder, Any) -> bool;

get_constant_member_printer :: (base_type: *Type_Info) -> Struct_Printer_Type {
    printer_info :: type_info(Struct_Printer_Type);
    result: Struct_Printer_Type = null;

    if base_type.type != .STRUCT return null;
    type := cast(*Type_Info_Struct) base_type;
    for type.members {
        if !(it.flags & .CONSTANT) continue;
        if it.name != "printer" continue;
        if it.type != printer_info continue;

        pointer := type.constant_storage.data + it.offset_into_constant_storage;
        result = cast(*Struct_Printer_Type, pointer).*;
        return result;
    }

    return null;
}

print_source_code_location :: (builder: *String_Builder, location: *Source_Code_Location) {
    filename := path_filename(location.fully_pathed_filename);
    print(builder, "%:%", filename, location.line_number);
}

Ascii_Or_Hex :: #type,distinct string;

print_ascii_or_hex :: (builder: *String_Builder, s: string) {
    for 0..s.count-1 {
        char := s[it];
        if char >= #char " " && char <= #char "~" {
            if char == #char "\\" || char == #char "\""
                append(builder, "\\");
            append(builder, char);
        } else {
            print_to_builder(builder, "\\x%", FormatInt.{ value = char, base = 16, minimum_digits = 2 });
        }
    }
}

//
// miscellaneous
//

Parse_Date_Time_Result :: enum_flags {
    DATE; TIME; MILLISECONDS;
    FULL :: DATE | TIME | MILLISECONDS;
}
parse_date_timestamp :: (input: string) -> (Calendar_Time, Parse_Date_Time_Result, tail: string) {
    _0 :: #char "0";

    result: Calendar_Time;
    // Won't be able to parse this
    result.day_of_week_starting_at_0 = -1;
    tail := input;

    status: Parse_Date_Time_Result;
    // Calendar_Time :: struct {
    //     year:        s32;
    //     month_starting_at_0: s8;         // 0-11. Use as an index to a month name array, or add 1 to get the normal human-readable number.
    //     day_of_month_starting_at_0: s8;  // 0-30. Add 1 to get the normal human-readable number.
    //     day_of_week_starting_at_0: s8;   // Sunday, Monday, Tuesday, Wednesday, Thursday, Friday, Saturday.
    //     hour:        s8;
    //     minute:      s8;
    //     second:      s8;
    //     millisecond: s16;
    //     time_zone: Time_Zone;
    // }

    cursor := 0;

    // skip whitespace
    while (cursor < input.count) && (inline is_space(input[cursor])) cursor += 1;
    tail = advance(input, cursor);
    if cursor >= input.count return result, status, tail;

    //
    // parse date `YYYY.MM.DD` (any separator)
    //
    if input.count - cursor < 10 return result, status, tail;

    // year
    {
        y0 := input[cursor]; cursor += 1;
        y1 := input[cursor]; cursor += 1;
        y2 := input[cursor]; cursor += 1;
        y3 := input[cursor]; cursor += 1;
        if !(inline is_digit(y0)) || !(inline is_digit(y1)) || !(inline is_digit(y2)) || !(inline is_digit(y3)) {
            return result, status, tail;
        }
        result.year = xx (cast(s32, y0 - _0) * 1000 + cast(s32, y1 - _0) * 100 + cast(s32, y2 - _0) * 10 + cast(s32, y3 - _0));
    }

    // separator
    sep := input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // month
    {
        m0 := xx input[cursor]; cursor += 1;
        m1 := xx input[cursor]; cursor += 1;
        if !(inline is_digit(m0)) || !(inline is_digit(m1)) return result, status, tail;
        result.month_starting_at_0 = xx ((m0 - _0) * 10 + (m1 - _0) - 1);
    }

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // day
    {
        d0 := xx input[cursor]; cursor += 1;
        d1 := xx input[cursor]; cursor += 1;
        if !(inline is_digit(d0)) || !(inline is_digit(d1)) return result, status, tail;
        result.day_of_month_starting_at_0 = xx ((d0 - _0) * 10 + (d1 - _0) - 1);
    }

    status = .DATE;
    tail = advance(input, cursor);
    if cursor >= input.count return result, status, tail;

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || ((inline is_alpha(sep)) && sep != #char "T") return result, status, tail;

    // skip whitespace
    while (cursor < input.count) && (inline is_space(input[cursor])) cursor += 1;
    tail = advance(input, cursor);
    if cursor >= input.count return result, status, tail;

    //
    // parse time `HH:MM:SS` (any separator)
    //
    if input.count - cursor < 8 return result, status, tail;

    // hour
    {
        h0 := xx input[cursor]; cursor += 1;
        h1 := xx input[cursor]; cursor += 1;
        if !(inline is_digit(h0)) || !(inline is_digit(h1)) return result, status, tail;
        result.hour = xx ((h0 - _0) * 10 + (h1 - _0));
    }

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // minute
    {
        m0 := input[cursor]; cursor += 1;
        m1 := input[cursor]; cursor += 1;
        if !(inline is_digit(m0)) || !(inline is_digit(m1)) return result, status, tail;
        result.minute = xx ((m0 - _0) * 10 + (m1 - _0));
    }

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // second
    {
        s0 := input[cursor]; cursor += 1;
        s1 := input[cursor]; cursor += 1;
        if !(inline is_digit(s0)) || !(inline is_digit(s1)) return result, status, tail;
        result.second = xx ((s0 - _0) * 10 + (s1 - _0));
    }

    status |= .TIME;
    tail = advance(input, cursor);

    //
    // parse millisecond `.MMM` (any separator)
    //
    if input.count - cursor < 4 return result, status, tail;

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, status, tail;

    // millisecond
    {
        m0 := input[cursor]; cursor += 1;
        m1 := input[cursor]; cursor += 1;
        m2 := input[cursor]; cursor += 1;
        if !(inline is_digit(m0)) || !(inline is_digit(m1)) || !(inline is_digit(m2)) return result, status, tail;
        result.millisecond = xx (cast(s16, m0 - _0) * 100 + cast(s16, m1 - _0) * 10 + cast(s16, m2 - _0));
    }

    status |= .MILLISECONDS;
    tail = advance(input, cursor);

    return result, status, tail;
}

test_parse_date_timestamp :: () {
    line: string;

    {
        line = "2025:02:26 17:05:33.047 tail";
        date_time, status, tail := parse_date_timestamp(line);
        assert(status == .FULL);
        assert(date_time.year == 2025);
        assert(date_time.month_starting_at_0 == 1);
        assert(date_time.day_of_month_starting_at_0 == 25);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 17);
        assert(date_time.minute == 5);
        assert(date_time.second == 33);
        assert(date_time.millisecond == 47);
        assert(tail == " tail");
    }

    {
        line = "  2003:03:13 no time?";
        date_time, status, tail := parse_date_timestamp(line);
        assert(status == .DATE);
        assert(date_time.year == 2003);
        assert(date_time.month_starting_at_0 == 2);
        assert(date_time.day_of_month_starting_at_0 == 12);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 0);
        assert(date_time.minute == 0);
        assert(date_time.second == 0);
        assert(date_time.millisecond == 0);
        assert(tail == "no time?");
    }

    {
        line = "1993:05:19 12:30:00 not accurate enough!";
        date_time, status, tail := parse_date_timestamp(line);
        assert(status == .DATE | .TIME);
        assert(date_time.year == 1993);
        assert(date_time.month_starting_at_0 == 4);
        assert(date_time.day_of_month_starting_at_0 == 18);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 12);
        assert(date_time.minute == 30);
        assert(date_time.second == 0);
        assert(date_time.millisecond == 0);
        assert(tail == " not accurate enough!");
    }

    {
        line = "  garbage!";
        date_time, status, tail := parse_date_timestamp(line);
        assert(status == 0);
        assert(date_time.year == 0);
        assert(date_time.month_starting_at_0 == 0);
        assert(date_time.day_of_month_starting_at_0 == 0);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 0);
        assert(date_time.minute == 0);
        assert(date_time.second == 0);
        assert(date_time.millisecond == 0);
        assert(tail == "garbage!");
    }

    {
        line = "";
        date_time, status, tail := parse_date_timestamp(line);
        assert(status == 0);
        assert(date_time.year == 0);
        assert(date_time.month_starting_at_0 == 0);
        assert(date_time.day_of_month_starting_at_0 == 0);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 0);
        assert(date_time.minute == 0);
        assert(date_time.second == 0);
        assert(date_time.millisecond == 0);
        assert(tail == "");
    }

    {
        line = "   \t  \n  \r ";
        date_time, status, tail := parse_date_timestamp(line);
        assert(status == 0);
        assert(date_time.year == 0);
        assert(date_time.month_starting_at_0 == 0);
        assert(date_time.day_of_month_starting_at_0 == 0);
        assert(date_time.day_of_week_starting_at_0 == -1);
        assert(date_time.hour == 0);
        assert(date_time.minute == 0);
        assert(date_time.second == 0);
        assert(date_time.millisecond == 0);
        assert(tail == "");
    }
}

Syslog_Line_Info :: struct {
    timestamp: Calendar_Time;
    hostname: string;
    process: string;
    pid: s32 = -1;

    timestamp_start: u8;
    timestamp_count: u8;
}

parse_syslog_prefix :: (input: string) -> (info: Syslog_Line_Info, ok: bool, tail: string) {
    _0 :: #char "0";

    result: Syslog_Line_Info;
    // Won't be able to parse this
    result.timestamp.day_of_week_starting_at_0 = -1;
    tail := input;

    cursor := 0;

    // skip whitespace
    while (cursor < input.count) && (inline is_space(input[cursor])) cursor += 1;
    tail = advance(input, cursor);
    if cursor >= input.count return result, false, tail;

    //
    // parse date `Month DD`
    //
    timestamp_start := cast(u8, cursor);

    month_start := cursor;
    // month
    {
        // skip non whitespace
        while cursor < input.count {
            c := input[cursor];
            if inline is_space(c) break;
            if !inline is_alpha(c) return result, false, tail;
            cursor += 1;
        }
        tail = advance(input, cursor);

        if cursor == month_start return result, false, tail;

        month_name := slice(input, month_start, cursor - month_start);

        supported_months :: string.["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        ok, month_starting_at_0 := array_find(supported_months, slice(month_name, 0, 3));
        if ok {
            result.timestamp.month_starting_at_0 = xx month_starting_at_0;
        }
    }

    // skip whitespace
    while (cursor < input.count) && (inline is_space(input[cursor])) cursor += 1;
    tail = advance(input, cursor);
    if cursor >= input.count return result, false, tail;

    // day
    if input.count - cursor < 2 return result, false, tail;
    {
        d0 := xx input[cursor]; cursor += 1;
        d1 := xx input[cursor]; cursor += 1;
        if !(inline is_digit(d0)) || !(inline is_digit(d1)) return result, false, tail;
        result.timestamp.day_of_month_starting_at_0 = xx ((d0 - _0) * 10 + (d1 - _0) - 1);
    }

    tail = advance(input, cursor);
    if cursor >= input.count return result, false, tail;

    // skip whitespace
    while (cursor < input.count) && (inline is_space(input[cursor])) cursor += 1;
    tail = advance(input, cursor);
    if cursor >= input.count return result, false, tail;

    //
    // parse time `HH:MM:SS` (any separator)
    //
    if input.count - cursor < 8 return result, false, tail;

    // hour
    {
        h0 := xx input[cursor]; cursor += 1;
        h1 := xx input[cursor]; cursor += 1;
        if !(inline is_digit(h0)) || !(inline is_digit(h1)) return result, false, tail;
        result.timestamp.hour = xx ((h0 - _0) * 10 + (h1 - _0));
    }

    // separator
    sep := input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, false, tail;

    // minute
    {
        m0 := input[cursor]; cursor += 1;
        m1 := input[cursor]; cursor += 1;
        if !(inline is_digit(m0)) || !(inline is_digit(m1)) return result, false, tail;
        result.timestamp.minute = xx ((m0 - _0) * 10 + (m1 - _0));
    }

    // separator
    sep = input[cursor]; cursor += 1;
    if (inline is_digit(sep)) || (inline is_alpha(sep)) return result, false, tail;

    // second
    {
        s0 := input[cursor]; cursor += 1;
        s1 := input[cursor]; cursor += 1;
        if !(inline is_digit(s0)) || !(inline is_digit(s1)) return result, false, tail;
        result.timestamp.second = xx ((s0 - _0) * 10 + (s1 - _0));
    }

    timestamp_count := cast(u8, cursor - timestamp_start);
    result.timestamp_start = timestamp_start;
    result.timestamp_count = timestamp_count;

    tail = advance(input, cursor);

    // skip whitespace
    while (cursor < input.count) && (inline is_space(input[cursor])) cursor += 1;
    tail = advance(input, cursor);
    if cursor >= input.count return result, false, tail;

    //
    // parse `$hostname $process[$pid]:`
    //

    // `$hostname`
    {
        hostname_start := cursor;

        // skip non whitespace
        while (cursor < input.count) && !(inline is_space(input[cursor])) cursor += 1;
        tail = advance(input, cursor);

        hostname_count := cursor - hostname_start;
        result.hostname = slice(input, hostname_start, hostname_count);
    }

    // skip whitespace
    while (cursor < input.count) && (inline is_space(input[cursor])) cursor += 1;
    tail = advance(input, cursor);
    if cursor >= input.count return result, false, tail;

    // `$process`
    {
        process_start := cursor;

        while (cursor < input.count) && (input[cursor] != #char "[") cursor += 1;
        tail = advance(input, cursor);

        process_count := cursor - process_start;
        result.process = slice(input, process_start, process_count);
    }

    // `[$pid]`
    {
        if input.count - cursor < 1 return result, false, tail;
        if input[cursor] != #char "[" return result, false, tail;
        cursor += 1;

        pid: s32 = 0;
        while cursor < input.count {
            c := input[cursor];
            if !inline is_digit(c) break;
            pid = pid * 10 + cast(s32, c - _0);
            cursor += 1;
        }

        if input.count - cursor < 1 return result, false, tail;
        if input[cursor] != #char "]" return result, false, tail;
        cursor += 1;

        result.pid = pid;
    }

    // `:`
    if cursor < input.count && input[cursor] == #char ":" then cursor += 1;
    tail = advance(input, cursor);

    //
    // finalize
    //

    if !current_year {
        current_year = to_calendar(current_time_consensus()).year;
    }
    result.timestamp.year = current_year;

    return result, true, tail;
}

current_year: s32;

common_prefix :: (values: [] string) -> string {
    if !values return "";

    best_so_far := values[0];
    for current: advance(values, 1) {
        if current.count < best_so_far.count {
            best_so_far.count = current.count;
        }

        for best_so_far {
            if it == current[it_index] continue;
            best_so_far.count = it_index;
            break;
        }

        if !best_so_far break;
    }

    return best_so_far;
}

common_postfix :: (values: [] string) -> string {
    if !values return "";

    best_so_far := values[0];
    for current: advance(values, 1) {
        overflow := best_so_far.count - current.count;
        if overflow > 0 {
            advance(*best_so_far, overflow);
        }

        i := 0;
        while i < best_so_far.count {
            if best_so_far[best_so_far.count - 1 - i] != current[current.count - 1 - i] {
                advance(*best_so_far, best_so_far.count - i);
                break;
            }
            i += 1;
        }

        if !best_so_far break;
    }

    return best_so_far;
}

extract_unique_middles :: (values: [] string) -> (pre: string, post: string, mids: [] string) {
    pre := common_prefix(values);
    post := common_postfix(values);
    mids: [..] string;

    for values {
        if pre == it {
            assert(post == pre);
            array_add(*mids, "");
            continue;
        }
        curr := it;
        curr = advance(curr, pre.count);
        curr = slice(curr, 0, curr.count - post.count);
        array_add(*mids, curr);
    }

    return pre, post, mids;
}

test_common_prefix_or_postfix :: () {
    values := string.[
        "foo/bar/baz.txt",
        "foo/bar/ballz.txt",
        "foo/biz.txt",
    ];

    pretty_assert(common_prefix(.[]) == "");
    pretty_assert(common_prefix(.["1"]) == "1");
    pretty_assert(common_prefix(.["ass"]) == "ass");
    pretty_assert(common_prefix(.["foooooooooo", "bor"]) == "");
    pretty_assert(common_prefix(values) == "foo/b");

    pretty_assert(common_postfix(.[]) == "");
    pretty_assert(common_postfix(.["1"]) == "1");
    pretty_assert(common_postfix(.["ass"]) == "ass");
    pretty_assert(common_postfix(.["foooooooooo", "bor"]) == "");
    pretty_assert(common_postfix(values) == "z.txt");

    pre: string;
    post: string;
    mids: [] string;

    pre, post, mids = extract_unique_middles(.[],, temp);
    pretty_assert(array_equals(mids, string.[]));
    pre, post, mids = extract_unique_middles(.["1"],, temp);
    pretty_assert(array_equals(mids, string.[""]));
    pre, post, mids = extract_unique_middles(.["ass"],, temp);
    pretty_assert(array_equals(mids, string.[""]));
    pre, post, mids = extract_unique_middles(.["foooooooooo", "bor"],, temp);
    pretty_assert(array_equals(mids, string.["foooooooooo", "bor"]));
    pre, post, mids = extract_unique_middles(values,, temp);
    pretty_assert(array_equals(mids, string.["ar/ba", "ar/ball", "i"]));
}

hex_color :: ($hex: string, $loc := #caller_location) -> Vector4 #expand {
    return #run -> Vector4 {
        result, ok := parse_hex_color(hex);
        assert(ok, "'%' is not a hex color", hex, loc=loc);
        context.logger = my_logger;
        // log("hex_color(\"%\") = %", hex, result, loc=loc);
        return result;
    };
}

parse_hex_color :: (hex: string) -> Vector4, bool {
    if hex.count != 6 return .{}, false;

    ok := false;

    rh:, ok = hex_digit(hex[0]); if !ok return .{}, false;
    rl:, ok = hex_digit(hex[1]); if !ok return .{}, false;

    gh:, ok = hex_digit(hex[2]); if !ok return .{}, false;
    gl:, ok = hex_digit(hex[3]); if !ok return .{}, false;

    bh:, ok = hex_digit(hex[4]); if !ok return .{}, false;
    bl:, ok = hex_digit(hex[5]); if !ok return .{}, false;

    result := Vector4.{
        (rh << 4 + rl) / 255.0,
        (gh << 4 + gl) / 255.0,
        (bh << 4 + bl) / 255.0,
        1,
    };
    return result, true;
}

is_hex_digit :: inline (c: u8) -> bool {
    return c >= #char "0" && c <= #char "9"
        || c >= #char "a" && c <= #char "f"
        || c >= #char "A" && c <= #char "F";
}

hex_digit :: inline (c: u8) -> u8, bool {
    if c >= #char "0" && c <= #char "9" {
        return c - #char "0", true;
    } else if c >= #char "a" && c <= #char "f" {
        return 10 + c - #char "a", true;
    } else if c >= #char "A" && c <= #char "F" {
        return 10 + c - #char "A", true;
    } else {
        return 0xff, false;
    }
}

resizable_array :: (items: [] $T) -> [..] T {
    result: [..] T;
    result.allocator = context.allocator;
    array_add(*result, .. items);
    return result;
}

resizable_array :: ($T: Type, reserve: int) -> [..] T {
    result: [..] T;
    result.allocator = context.allocator;
    array_reserve(*result, reserve);
    return result;
}

array_ordered_remove_range :: inline (array_pointer: *[] $T, start: s64, end: s64) {
    assert(0 <= start, "start: %", start);
    assert(start < array_pointer.count, "start: %, array_poniter.count: %", start, array_pointer.count);
    assert(start <= end, "start: %, end: %", start, end);
    assert(end <= array_pointer.count, "end: %, array_poniter.count: %", end, array_pointer.count);

    if start == end return;

    array := <<array_pointer;
    count := end - start;

    for i : start..array.count-count-1
        array[i] = array[i+count];

    array_pointer.count -= count;
}

array_insert_at :: (array: *[..] $T, items: [] T, index: int) {
    assert(index >= 0);
    assert(index <= array.count);
    if !items.count return;

    array_reserve(array, array.count + items.count);

    array.count += items.count;

    i := array.count-1;
    while i > index + items.count - 1 {
        array.data[i] = array.data[i-items.count];
        i -= 1;
    }

    memcpy(array.data + index, items.data, items.count * size_of(T));
}

// Stole this from modules/Sort. Made `f` polymorphic and inlined, this gives almost a 2x speed boost
// @Speed: This version of quick_sort (and probably the other one)
// seems to compare items to themselves a lot, which is clearly pointless.
// Fix that!
quick_sort :: inline (array: [] $T, $f: (T, T) -> $R) -> [] T {  // R is an integer type, but may be e.g. 32-bit.
    quicksort_helper :: (a: *T, n: s64) {
        if n < 2 return;

        p := a[n / 2];

        i := 0;
        j := n-1;

        while true {
            while (inline f(a[i], p)) < 0  {i += 1;}
            while (inline f(p, a[j])) < 0  {j -= 1;}

            if i >= j break;

            t := a[i];
            a[i] = a[j];
            a[j] = t;

            i += 1;
            j -= 1;
        }

        quicksort_helper(a, i);
        quicksort_helper(a + i, n - i);
    }

    quicksort_helper(array.data, array.count);
    return array;
}

// Stole this from modules/Sort. Minor changes. UPDATE what did I change and why???
quick_sort :: inline (array: [] $T, $f: (T) -> $R) -> [] T {  // R is an integer type, but may be e.g. 32-bit.
    quicksort_helper :: (a: *T, n: s64) {
        if n < 2 return;

        p := a[n / 2];

        i := 0;
        j := n-1;

        while true {
            fp := f(p);
            while f(a[i]) < fp  {i += 1;}
            while fp < f(a[j])  {j -= 1;}

            if i >= j break;

            t := a[i];
            a[i] = a[j];
            a[j] = t;

            i += 1;
            j -= 1;
        }

        quicksort_helper(a, i);
        quicksort_helper(a + i, n - i);
    }

    quicksort_helper(array.data, array.count);
    return array;
}

test_quick_sort :: () {
    array := int.[6, 1, 3, 5, 2, 4, 7, 0];
    quick_sort(array, (l, r) => l - r);
    assert(array_equals(array, .[0, 1, 2, 3, 4, 5, 6, 7]));

    array = int.[6, 1, 3, 5, 2, 4, 7, 0];
    quick_sort(array, (l, r) => r - l);
    assert(array_equals(array, .[7, 6, 5, 4, 3, 2, 1, 0]));
}

test_array_insert_at :: () {
    array: [..] int;

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    for 0..array.count {
        array_insert_at(*array, .[], it);
        assert(array_equals(array, .[1, 2, 3, 4, 5, 6]), "it: %, %", it, array);
    }

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 0);
    assert(array_equals(array, .[0xa, 0xb, 0xc, 1, 2, 3, 4, 5, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 1);
    assert(array_equals(array, .[1, 0xa, 0xb, 0xc, 2, 3, 4, 5, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 2);
    assert(array_equals(array, .[1, 2, 0xa, 0xb, 0xc, 3, 4, 5, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 3);
    assert(array_equals(array, .[1, 2, 3, 0xa, 0xb, 0xc, 4, 5, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 4);
    assert(array_equals(array, .[1, 2, 3, 4, 0xa, 0xb, 0xc, 5, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 5);
    assert(array_equals(array, .[1, 2, 3, 4, 5, 0xa, 0xb, 0xc, 6]), "%", array);

    array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    array_insert_at(*array, .[0xa, 0xb, 0xc], 6);
    assert(array_equals(array, .[1, 2, 3, 4, 5, 6, 0xa, 0xb, 0xc]), "%", array);

    // This one crashes:
    // array = resizable_array(int.[1, 2, 3, 4, 5, 6],, temp);
    // array_insert_at(*array, .[0xa, 0xb, 0xc], 7);

}

array_equals :: (a: [] $T, b: [] T) -> bool {
    if a.count != b.count return false;
    for a if it != b[it_index] return false;
    return true;
}

write_to_pointer :: inline (p: **u8, s: string) {
    memcpy(p.*, s.data, s.count);
    p.* += s.count;
}

compare_calendar_time :: (a: Calendar_Time, b: Calendar_Time) -> int {
    { t := a.year - b.year;                                             if t return t; }
    { t := a.month_starting_at_0 - b.month_starting_at_0;               if t return t; }
    { t := a.day_of_month_starting_at_0 - b.day_of_month_starting_at_0; if t return t; }
    { t := a.hour - b.hour;                                             if t return t; }
    { t := a.minute - b.minute;                                         if t return t; }
    { t := a.second - b.second;                                         if t return t; }
    return a.millisecond - b.millisecond;
}

operator < :: (a: Calendar_Time, b: Calendar_Time) -> bool {
    return (inline compare_calendar_time(a, b)) < 0;
}

operator <= :: (a: Calendar_Time, b: Calendar_Time) -> bool {
    return (inline compare_calendar_time(a, b)) <= 0;
}

operator > :: (a: Calendar_Time, b: Calendar_Time) -> bool {
    return (inline compare_calendar_time(a, b)) > 0;
}

operator >= :: (a: Calendar_Time, b: Calendar_Time) -> bool {
    return (inline compare_calendar_time(a, b)) >= 0;
}

operator == :: (a: Calendar_Time, b: Calendar_Time) -> bool {
    return (inline compare_calendar_time(a, b)) == 0;
}

advance :: inline (array: [] $T, bytes: s64) -> result: [] T {
    assert(array.count >= bytes);

    result := array;
    result.data  += bytes;
    result.count -= bytes;

    return result;
}

split_at :: (a: [] $T, i: int) -> ([] T, [] T) {
    assert(i >= 0, "%", i);
    assert(i <= a.count, "%", i);

    if i == 0 return .[], a;
    if i == a.count return a, .[];

    l: [] T = ---;
    l.data = a.data;
    l.count = i;

    r: [] T = ---;
    r.data = a.data + i;
    r.count = a.count - i;

    return l, r;
}

replace_in_place :: (s: string, old: u8, new: u8) -> string {
    cursor := 0;
    while true {
        cursor = find_index_from_left(s, old, cursor);
        if cursor == -1 break;
        s[cursor] = new;
    }
    return s;
}

split_at :: (s: string, i: int) -> (string, string) {
    l, r := inline split_at(cast([] u8) s, i);
    return xx l, xx r;
}

as_bytes :: (data: *$T, count: s64) -> [] u8 {
    result: [] u8 = ---;
    result.data = xx data;
    result.count = size_of(T) * count;
    return result;
}

min_max :: inline (a: $T, b: T) -> (min: T, max: T) {
    if a < b return a, b;
    return b, a;
}

last :: (s: [] string) -> u8 #expand {
    return s[s.count - 1];
}

last :: (array: [] $T) -> T #expand {
    return array[array.count - 1];
}

is_lower :: (s: string) -> bool {
    for s if (it < #char "a") || (it > #char "z") return false;
    return true;
}

is_upper :: inline (c: u8) -> bool {
    return c >= #char "A" && c <= #char "Z";
}

fmt :: (v: float64, trailing_width := 1) -> FormatFloat #expand {
    return FormatFloat.{ value = v, trailing_width = trailing_width, zero_removal = .NO };
}

fmt :: (v: float, trailing_width := 1) -> FormatFloat #expand {
    return FormatFloat.{ value = v, trailing_width = trailing_width, zero_removal = .NO };
}

profile_t0: float64 = 0.0;
Profile :: (format: string = "", args: ..Any, loc := #caller_location) #expand {
    t1 := seconds_since_init();
    elapsed := t1 - `profile_t0;
    if elapsed > .1 {
        msg := tprint(format, ..args);
        log("[elapsed: %]: %", elapsed, msg, loc=loc);
    }
    `profile_t0 = t1;
} @PrintLike

//
// pretty assert
//

// Constant structs don't work with compile time constructs yet, so we return
// all fields directly
get_expr_info :: (code: Code) -> kind: Code_Node.Kind, op_type: s32, full_expr: string, proc_expr: string, lhs: Code, rhs: Code {
    #import "Program_Print";

    root := compiler_get_nodes(code);

    builder: String_Builder;
    print_expression(*builder, root);
    full_expr := builder_to_string(*builder);

    if root.kind == {
        case .BINARY_OPERATOR;
            binop := cast(*Code_Binary_Operator) root;
            op_type := binop.operator_type;
            lhs := compiler_get_code(binop.left, code);
            rhs := compiler_get_code(binop.right, code);
            return xx root.kind, op_type, full_expr, "", lhs, rhs;

        case .PROCEDURE_CALL;
            proccall := cast(*Code_Procedure_Call) root;
            if proccall.arguments_sorted.count != 2 {
                dummy : Code = #code null;
                return xx root.kind, -1, full_expr, "", dummy, dummy;
            }

            builder: String_Builder;
            print_expression(*builder, proccall.procedure_expression);
            proc_expr := builder_to_string(*builder);

            lhs := compiler_get_code(proccall.arguments_sorted[0], code);
            rhs := compiler_get_code(proccall.arguments_sorted[1], code);
            return xx root.kind, -1, full_expr, proc_expr, lhs, rhs;

        case;

    }

    dummy : Code = #code null;
    return xx root.kind, -1, full_expr, "", dummy, dummy;
}

pretty_assert :: (code: Code, loc := #caller_location) #expand {
    if #insert code return;

    if context.handling_assertion_failure  return;  // Avoid infinite loops.
    context.handling_assertion_failure = true;

    kind, op_type, full_expr, proc_expr, lhs, rhs :: #run get_expr_info(code);

    message := "";

    #if kind == .BINARY_OPERATOR {
        builder : String_Builder;
        builder.allocator = temporary_allocator;

        print_to_builder(*builder, "(%) = (% ", full_expr, #insert lhs);

        if op_type < 128 {
            append(*builder, cast(u8) op_type);
        } else {
            append(*builder, operator_to_string(xx op_type));
        }

        print_to_builder(*builder, " %) = false", #insert rhs);
        message = builder_to_string(*builder,, temporary_allocator);
    } else #if kind == .PROCEDURE_CALL {
        message = tprint("(%) = (%(%, %)) = false", full_expr, proc_expr, #insert lhs, #insert rhs);
    } else {
        message = tprint("(%) = false", full_expr);
    }

    // We provide 'loc' in case _STACK_TRACE is turned off, but assertion_failed may well
    // look at the stack trace if it is available.
    context.assertion_failed(loc, message);
    debug_break();
    context.handling_assertion_failure = false;

} @NoProfile

//
// footer
//

test_parse_search_string :: () {
    {
        line := "$log_level=V";
        queries, ok := parse_search_string(line);
        assert(ok);
        assert(queries.match_any.count == 1);
        assert(queries.match_any[0].match_all.count == 1);
        query := queries.match_any[0].match_all[0];
        assert(query.type == .LOG_LEVEL, "%", query.type);
        pretty_assert(query.value == "V");
    }
    {
        line := "  $fiber_name=governor_loop  ";
        queries, ok := parse_search_string(line);
        assert(ok);
        assert(queries.match_any.count == 1);
        assert(queries.match_any[0].match_all.count == 1);
        query := queries.match_any[0].match_all[0];
        assert(query.type == .FIBER_NAME, "%", query.type);
        pretty_assert(query.value == "governor_loop");
    }
    {
        line := "$ module=vshard  ";
        queries, ok := parse_search_string(line);
        assert(!ok);
        assert(queries.match_any.count == 0);
    }
    {
        line := "$fiber_name=\"name with spaces\"  ";
        queries, ok := parse_search_string(line);
        assert(ok);
        assert(queries.match_any.count == 1);
        assert(queries.match_any[0].match_all.count == 1);
        query := queries.match_any[0].match_all[0];
        assert(query.type == .FIBER_NAME, "%", query.type);
        pretty_assert(query.value == "name with spaces");
    }
    {
        line := " $fiber_name=\"name with spaces\"  $log_level=E | $source=my_ass ";
        queries, ok := parse_search_string(line);
        assert(ok);
        assert(queries.match_any.count == 2);
        assert(queries.match_any[0].match_all.count == 2);
        query_0_0 := queries.match_any[0].match_all[0];
        assert(query_0_0.type == .FIBER_NAME, "%", query_0_0.type);
        pretty_assert(query_0_0.value == "name with spaces");
        query_0_1 := queries.match_any[0].match_all[1];
        assert(query_0_1.type == .LOG_LEVEL, "%", query_0_1.type);
        pretty_assert(query_0_1.value == "E");
        assert(queries.match_any[1].match_all.count == 1);
        query_1_0 := queries.match_any[1].match_all[0];
        assert(query_1_0.type == .SOURCE, "%", query_1_0.type);
        pretty_assert(query_1_0.value == "my_ass");
    }
    {
        line := " $thread_name=main  $fiber_id=\"999\" $ ";
        queries, ok := parse_search_string(line);
        assert(!ok);
        assert(queries.match_any.count == 1);
        assert(queries.match_any[0].match_all.count == 2);
        query_0_0 := queries.match_any[0].match_all[0];
        assert(query_0_0.type == .THREAD_NAME, "%", query_0_0.type);
        pretty_assert(query_0_0.value == "main");
        query_0_1 := queries.match_any[0].match_all[1];
        assert(query_0_1.type == .FIBER_ID, "%", query_0_1.type);
        pretty_assert(query_0_1.value == "999");
    }
}

test_parse_string_literal :: () {
    {
        line := #string END
"simple"
        END;
        out, ok := parse_string_literal(line,, temp);
        assert(ok);
        assert(out == "simple");
    }
    {
        line := #string END
"\"a\", \"b\", \"\\\""
        END;
        out, ok := parse_string_literal(line,, temp);
        assert(ok);
        expected := #string END
"a", "b", "\"
        END; // " // <- this comment fixes my vim syntax
        expected = trim_right(expected);
        assert(out == expected, "'%' '%'", out, expected);
    }
}

run_tests :: () {
    t0 := seconds_since_init();
    log("running tests...");
    log("test_search_for_match");          test_search_for_match();
    log("test_array_insert_at");           test_array_insert_at();
    log("test_quick_sort");                test_quick_sort();
    log("test_parse_date_timestamp");      test_parse_date_timestamp();
    log("test_parse_search_string");       test_parse_search_string();
    log("test_parse_string_literal");      test_parse_string_literal();
    log("test_common_prefix_or_postfix");  test_common_prefix_or_postfix();
    elapsed := seconds_since_init() - t0;
    log("\e[32mtests passed!\e[0m elapsed %", fmt(elapsed, 3));
}

WANTED_MSAA :: 8;

#import "Basic";
#import "String";
#import "Math";
#import "Window_Creation";
Input :: #import "Input";
Simp :: #import "Simp";
System :: #import "System";
#import "Hash_Table";
#import "File";
#import "File_Utilities";
#import "Clipboard";
#import "Pool";
Hash :: #import "Hash";
Default_Allocator :: #import "Default_Allocator";
#import "Compiler";
#import "Thread";
Sort :: #import "Sort";
#import "Atomics";
