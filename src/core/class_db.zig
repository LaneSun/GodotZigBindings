const gd = @import("api.zig");
const c = gd.c;

const std = @import("std");
const typeId = @import("typeid.zig").typeId;

const Wrapped = @import("wrapped.zig").Wrapped;
const Variant = @import("variant.zig").Variant;

var type_tag_parent_registry: std.AutoArrayHashMap(usize, usize) = undefined;

pub fn initTypeTagRegistry() void {
    type_tag_parent_registry = std.AutoArrayHashMap(usize, usize).init(std.heap.page_allocator);
}

pub fn deinitTypeTagRegistry() void {
    type_tag_parent_registry.deinit();
}

pub fn ensureTypeIsGodotClassPointer(comptime T: type) void {
    const type_info = @typeInfo(T);
    const type_tag = @typeInfo(std.builtin.TypeInfo).Union.tag_type.?;

    switch (type_info) {
        type_tag.Pointer => {
            const ptr_info = @typeInfo(type_info.Pointer.child);
            switch (ptr_info) {
                type_tag.Struct => {
                    if (!@hasDecl(type_info.Pointer.child, "GodotClass")) {
                        @compileError("Expected pointer to a Godot Class");
                    }
                },
                else => {
                    @compileError("Expected pointer to struct");
                },
            }
        },
        type_tag.Optional => {
            const optional_info = @typeInfo(type_info.Optional.child);
            const ptr_info = @typeInfo(optional_info.Pointer.child);
            switch (ptr_info) {
                type_tag.Struct => {
                    if (!@hasDecl(optional_info.Pointer.child, "GodotClass")) {
                        @compileError("Expected pointer to a Godot Class");
                    }
                },
                else => {
                    @compileError("Expected pointer to struct");
                },
            }
        },
        else => {
            @compileError("Expected pointer");
        },
    }
}

pub fn castTo(comptime class: type, object: anytype) ?*class { //This makes it less annoying to cast godot objects, without needing to dig for class.base:wrapped
    comptime ensureTypeIsGodotClassPointer(@TypeOf(object)); //While also still having compile time safety checks
    const wrapped = @ptrCast(?*Wrapped, object);
    return wrappedCastTo(class, wrapped);
}

pub fn wrappedCastTo(comptime class: type, object: ?*const Wrapped) ?*class {
    if (object == null) {
        return null;
    }

    if (comptime class.GodotClass.isClassScript()) {
        const custom_object = getCustomClassInstance(class, object.?);
        if (custom_object == null) {
            return null;
        }

        const wrapped = @ptrCast(?*Wrapped, custom_object).?;

        if (!isTypeKnown(wrapped.type_tag)) {
            return null;
        }

        if (isTypeCompatible(wrapped.type_tag, class.GodotClass.getId())) {
            return custom_object;
        }
    }
    else {
        if (!isTypeKnown(object.?.type_tag)) {
            return null;
        }

        if (isTypeCompatible(object.?.type_tag, class.GodotClass.getId())) {
            return @intToPtr(?*class, @ptrToInt(object));
        }
    }

    return null;
}

pub fn isTypeKnown(type_tag: usize) bool {
    return type_tag_parent_registry.get(type_tag) != null;
}

pub fn registerGlobalType(name: [*:0]const u8, type_tag: usize, base_type_tag: usize) void {
    gd.nativescript_1_1_api.*.godot_nativescript_set_global_type_tag.?(gd.language_index, name, @intToPtr(?*anyopaque, type_tag));
    
    registerType(type_tag, base_type_tag);
}

fn registerType(type_tag: usize, base_type_tag: usize) void {
    if (type_tag == base_type_tag) {
        return;
    }

    type_tag_parent_registry.put(type_tag, base_type_tag) catch unreachable;
}

fn isTypeCompatible(have_tag: usize, ask_tag: usize) bool {
    if (have_tag == 0) {
        return false;
    }

    var tag = have_tag;
    while (tag != 0) {
        if (tag == ask_tag) {
            return true;
        }

        tag = type_tag_parent_registry.get(tag).?;
    }

    return false;
}


pub fn getCustomClassInstance(comptime class: type, object: *const Wrapped) ?*class {
    comptime if (!class.GodotClass.isClassScript()) {
        @compileError("This function must only be used on custom classes");
    };

    const instance_data = gd.nativescript_api.*.godot_nativescript_get_userdata.?(object.owner);
    if (instance_data != null) {
        return @ptrCast(*class, @alignCast(@alignOf(*class), instance_data));
    }
    
    return null;
}

pub fn createCustomClassInstance(comptime class: type) *class { //TODO: The method binds could be cached
    comptime if (!class.GodotClass.isClassScript()) {
        @compileError("This function must only be used on custom classes");
    };

    const script_constructor = gd.api.*.godot_get_class_constructor.?("NativeScript");
    const mb_set_library = gd.api.*.godot_method_bind_get_method.?("NativeScript", "set_library");
    const mb_set_class_name = gd.api.*.godot_method_bind_get_method.?("NativeScript", "set_class_name");

    const script = script_constructor.?();
    {
        var args = [_]?*const anyopaque { gd.gndlib };
        gd.api.*.godot_method_bind_ptrcall.?(mb_set_library, script, &args, null);
    }
    {
        var godot_string: c.godot_string = undefined;
        gd.api.*.godot_string_new.?(&godot_string);
        _ = gd.api.*.godot_string_parse_utf8.?(&godot_string, class.GodotClass.getClassName());
        defer gd.api.*.godot_string_destroy.?(&godot_string);

        var args = [_]?*const anyopaque { &godot_string };
        gd.api.*.godot_method_bind_ptrcall.?(mb_set_class_name, script, &args, null);
    }

    const base_constructor = gd.api.*.godot_get_class_constructor.?(class.GodotClass.getGodotClassName());
    const mb_set_script = gd.api.*.godot_method_bind_get_method.?("Object", "set_script");

    const base_object = base_constructor.?();
    {
        var args = [_]?*const anyopaque { script };
        gd.api.*.godot_method_bind_ptrcall.?(mb_set_script, base_object, &args, null);
    }

    const instance_data = gd.nativescript_api.*.godot_nativescript_get_userdata.?(base_object);
    return @ptrCast(*class, @alignCast(@alignOf(*class), instance_data));
}


// This is used to declare your Godot Class like this: const GodotClass = DefineGodotClass(MyNode, Node);
pub fn DefineGodotClass(comptime class: type, comptime base: type) type {
    return struct {

        pub inline fn isClassScript() bool {
            return true;
        }

        pub inline fn getClassName() [*:0]const u8 {
            return @typeName(class);
        }

        pub inline fn getBaseClassName() [*:0]const u8 {
            return base.GodotClass.getClassName();
        }

        pub inline fn getGodotClassName() [*:0]const u8 {
            return base.GodotClass.getClassName();
        }

        pub inline fn getId() usize {
            return typeId(class);
        }

        pub inline fn getBaseId() usize {
            return base.GodotClass.getId();
        }

        pub inline fn memnew() *class {
            return createCustomClassInstance(class);
        }

    };
}


pub fn registerClass(comptime class: type) void {
    comptime if (!class.GodotClass.isClassScript()) {
        @compileError("This function must only be used on custom classes");
    };

    const create = c.godot_instance_create_func {
        .create_func = class.constructor,
        .method_data = null,
        .free_func = null,
    };

    const destroy = c.godot_instance_destroy_func {
        .destroy_func = class.destructor,
        .method_data = null,
        .free_func = null,
    };

    gd.nativescript_api.*.godot_nativescript_register_class.?(gd.nativescript_handle, class.GodotClass.getClassName(), class.GodotClass.getBaseClassName(), create, destroy);

    registerType(class.GodotClass.getId(), class.GodotClass.getBaseId());
    gd.nativescript_1_1_api.*.godot_nativescript_set_type_tag.?(gd.nativescript_handle, class.GodotClass.getClassName(), @intToPtr(?*anyopaque, class.GodotClass.getId()));

    class.registerMembers();
}


fn FunctionWrapper(comptime function: anytype) type {
    return extern struct {

        fn functionWrap(godot_object: ?*c.godot_object, method_data: ?*const anyopaque, user_data: ?*anyopaque, arg_count: c_int, args: [*c][*c]c.godot_variant) callconv(.C) c.godot_variant {
            _ = godot_object;
            _ = method_data;
            _ = user_data;
            _ = arg_count;

            const fn_info = @typeInfo(@TypeOf(function)).Fn;

            switch(fn_info.args.len) { //TODO: Find if its possible to this automatically
                1 => {
                    const result = @call(.{}, function, .{
                        Variant.variantAsType(fn_info.args[0].arg_type.?)(args[0]),
                    });
                    
                    return Variant.typeAsVariant(fn_info.return_type.?)(result);
                },
                2 => {
                    const result = @call(.{}, function, .{
                        Variant.variantAsType(fn_info.args[0].arg_type.?)(args[0]),
                        Variant.variantAsType(fn_info.args[1].arg_type.?)(args[1]),
                    });
                    
                    return Variant.typeAsVariant(fn_info.return_type.?)(result);
                },
                3 => {
                    const result = @call(.{}, function, .{
                        Variant.variantAsType(fn_info.args[0].arg_type.?)(args[0]),
                        Variant.variantAsType(fn_info.args[1].arg_type.?)(args[1]),
                        Variant.variantAsType(fn_info.args[2].arg_type.?)(args[2]),
                    });
                    
                    return Variant.typeAsVariant(fn_info.return_type.?)(result);
                },
                4 => {
                    const result = @call(.{}, function, .{
                        Variant.variantAsType(fn_info.args[0].arg_type.?)(args[0]),
                        Variant.variantAsType(fn_info.args[1].arg_type.?)(args[1]),
                        Variant.variantAsType(fn_info.args[2].arg_type.?)(args[2]),
                        Variant.variantAsType(fn_info.args[3].arg_type.?)(args[3]),
                    });

                    return Variant.typeAsVariant(fn_info.return_type.?)(result);
                },
                5 => {
                    const result = @call(.{}, function, .{
                        Variant.variantAsType(fn_info.args[0].arg_type.?)(args[0]),
                        Variant.variantAsType(fn_info.args[1].arg_type.?)(args[1]),
                        Variant.variantAsType(fn_info.args[2].arg_type.?)(args[2]),
                        Variant.variantAsType(fn_info.args[3].arg_type.?)(args[3]),
                        Variant.variantAsType(fn_info.args[4].arg_type.?)(args[4]),
                    });

                    return Variant.typeAsVariant(fn_info.return_type.?)(result);
                },
                else => {
                    @compileError("Unsupported arg count");
                },
            }
        }

    };
}

pub fn registerFunction(comptime class: type, name: [*:0]const u8, comptime method: anytype, rpc_type: c.godot_method_rpc_mode) void {
    comptime if (!class.GodotClass.isClassScript()) {
        @compileError("This function must only be used on custom classes");
    };

    const function_wrapper = FunctionWrapper(method);

    const instance = c.godot_instance_method {
        .method = function_wrapper.functionWrap,
        .method_data = null,
        .free_func = null,
    };

    const attributes = c.godot_method_attributes {
        .rpc_type = rpc_type,
    };

    gd.nativescript_api.*.godot_nativescript_register_method.?(gd.nativescript_handle, class.GodotClass.getClassName(), name, attributes, instance);
}


fn MethodWrapper(comptime class: type, comptime function: anytype) type {
    return extern struct {

        fn functionWrap(godot_object: ?*c.godot_object, method_data: ?*const anyopaque, user_data: ?*anyopaque, arg_count: c_int, args: [*c][*c]c.godot_variant) callconv(.C) c.godot_variant {
            _ = godot_object;
            _ = method_data;
            _ = arg_count;

            const fn_info = @typeInfo(@TypeOf(function)).Fn;
            const struct_instance = @ptrCast(*class, @alignCast(@alignOf(*class), user_data));

            comptime if (fn_info.args.len == 0) {
                @compileError("A method needs to take atleast the struct parameter");
            };

            comptime if (fn_info.args[0].arg_type.? != *class and fn_info.args[0].arg_type.? != *const class) {
                @compileError("The first parameter of a method should be the struct");
            };

            switch(fn_info.args.len) { //TODO: Find if its possible to this automatically
                1 => {
                    const result = @call(.{}, function, .{
                        struct_instance,
                    });
                    
                    return Variant.typeAsVariant(fn_info.return_type.?)(result);
                },
                2 => {
                    const result = @call(.{}, function, .{
                        struct_instance,
                        Variant.variantAsType(fn_info.args[1].arg_type.?)(args[0]),
                    });
                    
                    return Variant.typeAsVariant(fn_info.return_type.?)(result);
                },
                3 => {
                    const result = @call(.{}, function, .{
                        struct_instance,
                        Variant.variantAsType(fn_info.args[1].arg_type.?)(args[0]),
                        Variant.variantAsType(fn_info.args[2].arg_type.?)(args[1]),
                    });
                    
                    return Variant.typeAsVariant(fn_info.return_type.?)(result);
                },
                4 => {
                    const result = @call(.{}, function, .{
                        struct_instance,
                        Variant.variantAsType(fn_info.args[1].arg_type.?)(args[0]),
                        Variant.variantAsType(fn_info.args[2].arg_type.?)(args[1]),
                        Variant.variantAsType(fn_info.args[3].arg_type.?)(args[2]),
                    });

                    return Variant.typeAsVariant(fn_info.return_type.?)(result);
                },
                5 => {
                    const result = @call(.{}, function, .{
                        struct_instance,
                        Variant.variantAsType(fn_info.args[1].arg_type.?)(args[0]),
                        Variant.variantAsType(fn_info.args[2].arg_type.?)(args[1]),
                        Variant.variantAsType(fn_info.args[3].arg_type.?)(args[2]),
                        Variant.variantAsType(fn_info.args[4].arg_type.?)(args[3]),
                    });

                    return Variant.typeAsVariant(fn_info.return_type.?)(result);
                },
                else => {
                    @compileError("Unsupported arg count");
                },
            }
        }

    };
}

pub fn registerMethod(comptime class: type, name: [*:0]const u8, comptime method: anytype, rpc_type: c.godot_method_rpc_mode) void {
    comptime if (!class.GodotClass.isClassScript()) {
        @compileError("This function must only be used on custom classes");
    };

    const method_wrapper = MethodWrapper(class, method);

    const instance = c.godot_instance_method {
        .method = method_wrapper.functionWrap,
        .method_data = null,
        .free_func = null,
    };

    const attributes = c.godot_method_attributes {
        .rpc_type = rpc_type,
    };

    gd.nativescript_api.*.godot_nativescript_register_method.?(gd.nativescript_handle, class.GodotClass.getClassName(), name, attributes, instance);
}


fn PropertyDefaultSetWrapper(comptime class: type, comptime field_name: []const u8) type {
    return extern struct {

        fn functionWrap(godot_object: ?*c.godot_object, method_data: ?*const anyopaque, user_data: ?*anyopaque, variant_value: [*c]c.godot_variant) callconv(.C) void {
            _ = godot_object;
            _ = method_data;

            const struct_instance = @ptrCast(*class, @alignCast(@alignOf(*class), user_data));
            const field_type = @TypeOf(@field(struct_instance, field_name));
            const value = Variant.variantAsType(field_type)(variant_value);
            @field(struct_instance, field_name) = value;
        }

    };
}

fn PropertyDefaultGetWrapper(comptime class: type, comptime field_name: []const u8) type {
    return extern struct {
        
        fn functionWrap(godot_object: ?*c.godot_object, method_data: ?*const anyopaque, user_data: ?*anyopaque) callconv(.C) c.godot_variant {
            _ = godot_object;
            _ = method_data;

            const struct_instance = @ptrCast(*class, @alignCast(@alignOf(*class), user_data));
            const field_type = @TypeOf(@field(struct_instance, field_name));
            const value = @field(struct_instance, field_name);
            return Variant.typeAsVariant(field_type)(value);
        }

    };
}

fn PropertySetWrapper(comptime class: type, comptime function: anytype) type {
    return extern struct {

        fn functionWrap(godot_object: ?*c.godot_object, method_data: ?*const anyopaque, user_data: ?*anyopaque, variant_value: [*c]c.godot_variant) callconv(.C) void {
            _ = godot_object;
            _ = method_data;

            const fn_info = @typeInfo(@TypeOf(function)).Fn;
            const struct_instance = @ptrCast(*class, @alignCast(@alignOf(*class), user_data));

            _ = @call(.{}, function, .{ struct_instance, Variant.variantAsType(fn_info.args[1].arg_type.?)(variant_value) });
        }

    };
}

fn PropertyGetWrapper(comptime class: type, comptime function: anytype) type {
    return extern struct {

        fn functionWrap(godot_object: ?*c.godot_object, method_data: ?*const anyopaque, user_data: ?*anyopaque) callconv(.C) c.godot_variant {
            _ = godot_object;
            _ = method_data;

            const fn_info = @typeInfo(@TypeOf(function)).Fn;
            const struct_instance = @ptrCast(*class, @alignCast(@alignOf(*class), user_data));

            const result = @call(.{}, function, .{ struct_instance });
            return Variant.typeAsVariant(fn_info.return_type.?)(result);
        }

    };
}

pub fn registerProperty(comptime class: type, name: [*:0]const u8, comptime field_name: []const u8, default_value: anytype, comptime setter: anytype, comptime getter: anytype, rpc_mode: c.godot_method_rpc_mode, usage: c.godot_property_usage_flags, hint: c.godot_property_hint, hint_string: [*:0]const u8) void {
    comptime if (!class.GodotClass.isClassScript()) {
        @compileError("This function must only be used on custom classes");
    };

    const godot_variant = Variant.typeAsVariant(@TypeOf(default_value))(default_value);

    var godot_string_hint: c.godot_string = undefined;
    gd.api.*.godot_string_new.?(&godot_string_hint);
    _ = gd.api.*.godot_string_parse_utf8.?(&godot_string_hint, hint_string);
    defer gd.api.*.godot_string_destroy.?(&godot_string_hint);

    var attributes: c.godot_property_attributes = undefined;
    attributes.type = @intCast(c_int, gd.api.*.godot_variant_get_type.?(&godot_variant));
    attributes.default_value = godot_variant;
    attributes.hint = hint;
    attributes.rset_type = rpc_mode;
    attributes.usage = usage;
    attributes.hint_string = godot_string_hint;

    const set_wrapper = if (@TypeOf(setter) == @TypeOf(null)) PropertyDefaultSetWrapper(class, field_name) else PropertySetWrapper(class, setter);

    var set_func: c.godot_property_set_func = undefined;
    set_func.set_func = set_wrapper.functionWrap;
    set_func.method_data = null;
    set_func.free_func = null;

    const get_wrapper = if (@TypeOf(getter) == @TypeOf(null)) PropertyDefaultGetWrapper(class, field_name) else PropertyGetWrapper(class, getter);

    var get_func: c.godot_property_get_func = undefined;
    get_func.get_func = get_wrapper.functionWrap;
    get_func.method_data = null;
    get_func.free_func = null;

    gd.nativescript_api.*.godot_nativescript_register_property.?(gd.nativescript_handle, class.GodotClass.getClassName(), name, &attributes, set_func, get_func);
}

pub fn registerSignal(comptime class: type, name: [*:0]const u8, comptime args: anytype) void {
    comptime if (!class.GodotClass.isClassScript()) {
        @compileError("This function must only be used on custom classes");
    };

    var signal_name: c.godot_string = undefined;
    gd.api.*.godot_string_new.?(&signal_name);
    _ = gd.api.*.godot_string_parse_utf8.?(&signal_name, name);
    defer gd.api.*.godot_string_destroy.?(&signal_name);

    var signal: c.godot_signal = undefined;
    signal.name = signal_name;
    signal.num_args = args.len;
    signal.args = null;
    signal.num_default_args = 0;
    signal.default_args = null;

    if (args.len > 0) {
        const arg_data_size = signal.num_args * @sizeOf(c.godot_signal_argument);
        const arg_data = gd.api.*.godot_alloc.?(arg_data_size);
        signal.args = @ptrCast([*c]c.godot_signal_argument, @alignCast(@alignOf([*c]c.godot_signal_argument), arg_data));
        defer gd.api.*.godot_free.?(signal.args);
        @memset(@ptrCast([*]u8, arg_data), 0, @intCast(usize, arg_data_size));

        inline for (args) |arg, i| {
            const arg_name = arg[0];
            const arg_type = @enumToInt(Variant.typeToVariantType(arg[1]));
            
            var arg_name_string: c.godot_string = undefined;
            gd.api.*.godot_string_new.?(&arg_name_string);
            _ = gd.api.*.godot_string_parse_utf8.?(&arg_name_string, arg_name);
            //Allocated string memory handled/freed by Godot

            signal.args[i].name = arg_name_string;
            signal.args[i].type = arg_type;
        }
    }

    gd.nativescript_api.*.godot_nativescript_register_signal.?(gd.nativescript_handle, class.GodotClass.getClassName(), &signal);
}
