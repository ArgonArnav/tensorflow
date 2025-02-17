# Platform-specific build configurations.

load("@com_google_protobuf//:protobuf.bzl", "proto_gen")
load("//tensorflow:tensorflow.bzl", "if_not_windows")
load("//tensorflow/core/platform:default/build_config_root.bzl", "if_static")
load("@local_config_cuda//cuda:build_defs.bzl", "if_cuda")
load("@local_config_rocm//rocm:build_defs.bzl", "if_rocm")
load(
    "//third_party/mkl:build_defs.bzl",
    "if_mkl_ml",
)

# Appends a suffix to a list of deps.
def tf_deps(deps, suffix):
    tf_deps = []

    # If the package name is in shorthand form (ie: does not contain a ':'),
    # expand it to the full name.
    for dep in deps:
        tf_dep = dep

        if not ":" in dep:
            dep_pieces = dep.split("/")
            tf_dep += ":" + dep_pieces[len(dep_pieces) - 1]

        tf_deps += [tf_dep + suffix]

    return tf_deps

# Modified from @cython//:Tools/rules.bzl
def pyx_library(
        name,
        deps = [],
        py_deps = [],
        srcs = [],
        testonly = None,
        srcs_version = "PY2AND3",
        **kwargs):
    """Compiles a group of .pyx / .pxd / .py files.

    First runs Cython to create .cpp files for each input .pyx or .py + .pxd
    pair. Then builds a shared object for each, passing "deps" to each cc_binary
    rule (includes Python headers by default). Finally, creates a py_library rule
    with the shared objects and any pure Python "srcs", with py_deps as its
    dependencies; the shared objects can be imported like normal Python files.

    Args:
      name: Name for the rule.
      deps: C/C++ dependencies of the Cython (e.g. Numpy headers).
      py_deps: Pure Python dependencies of the final library.
      srcs: .py, .pyx, or .pxd files to either compile or pass through.
      **kwargs: Extra keyword arguments passed to the py_library.
    """

    # First filter out files that should be run compiled vs. passed through.
    py_srcs = []
    pyx_srcs = []
    pxd_srcs = []
    for src in srcs:
        if src.endswith(".pyx") or (src.endswith(".py") and
                                    src[:-3] + ".pxd" in srcs):
            pyx_srcs.append(src)
        elif src.endswith(".py"):
            py_srcs.append(src)
        else:
            pxd_srcs.append(src)
        if src.endswith("__init__.py"):
            pxd_srcs.append(src)

    # Invoke cython to produce the shared object libraries.
    for filename in pyx_srcs:
        native.genrule(
            name = filename + "_cython_translation",
            srcs = [filename],
            outs = [filename.split(".")[0] + ".cpp"],
            # Optionally use PYTHON_BIN_PATH on Linux platforms so that python 3
            # works. Windows has issues with cython_binary so skip PYTHON_BIN_PATH.
            cmd = "PYTHONHASHSEED=0 $(location @cython//:cython_binary) --cplus $(SRCS) --output-file $(OUTS)",
            testonly = testonly,
            tools = ["@cython//:cython_binary"] + pxd_srcs,
        )

    shared_objects = []
    for src in pyx_srcs:
        stem = src.split(".")[0]
        shared_object_name = stem + ".so"
        native.cc_binary(
            name = shared_object_name,
            srcs = [stem + ".cpp"],
            deps = deps + ["@org_tensorflow//third_party/python_runtime:headers"],
            linkshared = 1,
            testonly = testonly,
        )
        shared_objects.append(shared_object_name)

    # Now create a py_library with these shared objects as data.
    native.py_library(
        name = name,
        srcs = py_srcs,
        deps = py_deps,
        srcs_version = srcs_version,
        data = shared_objects,
        testonly = testonly,
        **kwargs
    )

def _proto_cc_hdrs(srcs, use_grpc_plugin = False):
    ret = [s[:-len(".proto")] + ".pb.h" for s in srcs]
    if use_grpc_plugin:
        ret += [s[:-len(".proto")] + ".grpc.pb.h" for s in srcs]
    return ret

def _proto_cc_srcs(srcs, use_grpc_plugin = False):
    ret = [s[:-len(".proto")] + ".pb.cc" for s in srcs]
    if use_grpc_plugin:
        ret += [s[:-len(".proto")] + ".grpc.pb.cc" for s in srcs]
    return ret

def _proto_py_outs(srcs, use_grpc_plugin = False):
    ret = [s[:-len(".proto")] + "_pb2.py" for s in srcs]
    if use_grpc_plugin:
        ret += [s[:-len(".proto")] + "_pb2_grpc.py" for s in srcs]
    return ret

# Re-defined protocol buffer rule to allow building "header only" protocol
# buffers, to avoid duplicate registrations. Also allows non-iterable cc_libs
# containing select() statements.
def cc_proto_library(
        name,
        srcs = [],
        deps = [],
        cc_libs = [],
        include = None,
        protoc = "@com_google_protobuf//:protoc",
        internal_bootstrap_hack = False,
        use_grpc_plugin = False,
        use_grpc_namespace = False,
        make_default_target_header_only = False,
        protolib_name = None,
        protolib_deps = [],
        **kargs):
    """Bazel rule to create a C++ protobuf library from proto source files.

    Args:
      name: the name of the cc_proto_library.
      srcs: the .proto files of the cc_proto_library.
      deps: a list of dependency labels; must be cc_proto_library.
      cc_libs: a list of other cc_library targets depended by the generated
          cc_library.
      include: a string indicating the include path of the .proto files.
      protoc: the label of the protocol compiler to generate the sources.
      internal_bootstrap_hack: a flag indicate the cc_proto_library is used only
          for bootstraping. When it is set to True, no files will be generated.
          The rule will simply be a provider for .proto files, so that other
          cc_proto_library can depend on it.
      use_grpc_plugin: a flag to indicate whether to call the grpc C++ plugin
          when processing the proto files.
      use_grpc_namespace: the namespace for the grpc services.
      make_default_target_header_only: Controls the naming of generated
          rules. If True, the `name` rule will be header-only, and an _impl rule
          will contain the implementation. Otherwise the header-only rule (name
          + "_headers_only") must be referred to explicitly.
      protolib_name: the name for the proto library generated by this rule.
      protolib_deps: The dependencies to proto libraries.
      **kargs: other keyword arguments that are passed to cc_library.
    """

    includes = []
    if include != None:
        includes = [include]
    if protolib_name == None:
        protolib_name = name
    if not protolib_deps:
        protolib_deps = deps

    if internal_bootstrap_hack:
        # For pre-checked-in generated files, we add the internal_bootstrap_hack
        # which will skip the codegen action.
        proto_gen(
            name = protolib_name + "_genproto",
            srcs = srcs,
            includes = includes,
            protoc = protoc,
            visibility = ["//visibility:public"],
            deps = [s + "_genproto" for s in protolib_deps],
        )

        # An empty cc_library to make rule dependency consistent.
        native.cc_library(
            name = name,
            **kargs
        )
        return

    grpc_cpp_plugin = None
    plugin_options = []
    if use_grpc_plugin:
        grpc_cpp_plugin = "//external:grpc_cpp_plugin"
        if use_grpc_namespace:
            plugin_options = ["services_namespace=grpc"]

    gen_srcs = _proto_cc_srcs(srcs, use_grpc_plugin)
    gen_hdrs = _proto_cc_hdrs(srcs, use_grpc_plugin)
    outs = gen_srcs + gen_hdrs

    proto_gen(
        name = protolib_name + "_genproto",
        srcs = srcs,
        outs = outs,
        gen_cc = 1,
        includes = includes,
        plugin = grpc_cpp_plugin,
        plugin_language = "grpc",
        plugin_options = plugin_options,
        protoc = protoc,
        visibility = ["//visibility:public"],
        deps = [s + "_genproto" for s in protolib_deps],
    )

    if use_grpc_plugin:
        cc_libs += select({
            "//tensorflow:linux_s390x": ["//external:grpc_lib_unsecure"],
            "//conditions:default": ["//external:grpc_lib"],
        })

    if make_default_target_header_only:
        header_only_name = name
        impl_name = name + "_impl"
    else:
        header_only_name = name + "_headers_only"
        impl_name = name

    native.cc_library(
        name = impl_name,
        srcs = gen_srcs,
        hdrs = gen_hdrs,
        deps = cc_libs + deps,
        includes = includes,
        alwayslink = 1,
        **kargs
    )
    native.cc_library(
        name = header_only_name,
        deps = ["@com_google_protobuf//:protobuf_headers"] + if_static([impl_name]),
        hdrs = gen_hdrs,
        **kargs
    )

    # Temporarily also add an alias with the 'protolib_name'. So far we relied
    # on copybara to switch dependencies to the _cc dependencies. Now that these
    # copybara rules are removed, we need to first change the internal BUILD
    # files to depend on the correct targets instead, then this can be removed.
    # TODO(b/143648532): Remove this once all reverse dependencies are migrated.
    if protolib_name != name:
        native.alias(
            name = protolib_name,
            actual = name,
            visibility = kargs["visibility"],
        )

# Re-defined protocol buffer rule to bring in the change introduced in commit
# https://github.com/google/protobuf/commit/294b5758c373cbab4b72f35f4cb62dc1d8332b68
# which was not part of a stable protobuf release in 04/2018.
# TODO(jsimsa): Remove this once the protobuf dependency version is updated
# to include the above commit.
def py_proto_library(
        name,
        srcs = [],
        deps = [],
        py_libs = [],
        py_extra_srcs = [],
        include = None,
        default_runtime = "@com_google_protobuf//:protobuf_python",
        protoc = "@com_google_protobuf//:protoc",
        use_grpc_plugin = False,
        **kargs):
    """Bazel rule to create a Python protobuf library from proto source files

    NOTE: the rule is only an internal workaround to generate protos. The
    interface may change and the rule may be removed when bazel has introduced
    the native rule.

    Args:
      name: the name of the py_proto_library.
      srcs: the .proto files of the py_proto_library.
      deps: a list of dependency labels; must be py_proto_library.
      py_libs: a list of other py_library targets depended by the generated
          py_library.
      py_extra_srcs: extra source files that will be added to the output
          py_library. This attribute is used for internal bootstrapping.
      include: a string indicating the include path of the .proto files.
      default_runtime: the implicitly default runtime which will be depended on by
          the generated py_library target.
      protoc: the label of the protocol compiler to generate the sources.
      use_grpc_plugin: a flag to indicate whether to call the Python C++ plugin
          when processing the proto files.
      **kargs: other keyword arguments that are passed to py_library.
    """
    outs = _proto_py_outs(srcs, use_grpc_plugin)

    includes = []
    if include != None:
        includes = [include]

    grpc_python_plugin = None
    if use_grpc_plugin:
        grpc_python_plugin = "//external:grpc_python_plugin"
        # Note: Generated grpc code depends on Python grpc module. This dependency
        # is not explicitly listed in py_libs. Instead, host system is assumed to
        # have grpc installed.

    proto_gen(
        name = name + "_genproto",
        srcs = srcs,
        outs = outs,
        gen_py = 1,
        includes = includes,
        plugin = grpc_python_plugin,
        plugin_language = "grpc",
        protoc = protoc,
        visibility = ["//visibility:public"],
        deps = [s + "_genproto" for s in deps],
    )

    if default_runtime and not default_runtime in py_libs + deps:
        py_libs = py_libs + [default_runtime]

    native.py_library(
        name = name,
        srcs = outs + py_extra_srcs,
        deps = py_libs + deps,
        imports = includes,
        **kargs
    )

def tf_proto_library_cc(
        name,
        srcs = [],
        has_services = None,
        protodeps = [],
        visibility = None,
        testonly = 0,
        cc_libs = [],
        cc_stubby_versions = None,
        cc_grpc_version = None,
        j2objc_api_version = 1,
        cc_api_version = 2,
        js_codegen = "jspb",
        make_default_target_header_only = False):
    js_codegen = js_codegen  # unused argument
    native.filegroup(
        name = name + "_proto_srcs",
        srcs = srcs + tf_deps(protodeps, "_proto_srcs"),
        testonly = testonly,
        visibility = visibility,
    )

    use_grpc_plugin = None
    if cc_grpc_version:
        use_grpc_plugin = True

    protolib_deps = tf_deps(protodeps, "")
    cc_deps = tf_deps(protodeps, "_cc")
    cc_name = name + "_cc"
    if not srcs:
        # This is a collection of sub-libraries. Build header-only and impl
        # libraries containing all the sources.
        proto_gen(
            name = name + "_genproto",
            protoc = "@com_google_protobuf//:protoc",
            visibility = ["//visibility:public"],
            deps = [s + "_genproto" for s in protolib_deps],
        )

        # Temporarily also add an alias with 'name'. So far we relied on
        # copybara to switch dependencies to the _cc dependencies. Now that these
        # copybara rules are removed, we need to change the internal BUILD files to
        # depend on the correct targets instead.
        # TODO(b/143648532): Remove this once all reverse dependencies are
        # migrated.
        native.alias(
            name = name,
            actual = cc_name,
            testonly = testonly,
            visibility = visibility,
        )
        native.cc_library(
            name = cc_name,
            deps = cc_deps + ["@com_google_protobuf//:protobuf_headers"] + if_static([name + "_cc_impl"]),
            testonly = testonly,
            visibility = visibility,
        )
        native.cc_library(
            name = cc_name + "_impl",
            deps = [s + "_impl" for s in cc_deps] + ["@com_google_protobuf//:cc_wkt_protos"],
        )

        return

    cc_proto_library(
        name = cc_name,
        protolib_name = name,
        testonly = testonly,
        srcs = srcs,
        cc_libs = cc_libs + if_static(
            ["@com_google_protobuf//:protobuf"],
            ["@com_google_protobuf//:protobuf_headers"],
        ),
        copts = if_not_windows([
            "-Wno-unknown-warning-option",
            "-Wno-unused-but-set-variable",
            "-Wno-sign-compare",
        ]),
        make_default_target_header_only = make_default_target_header_only,
        protoc = "@com_google_protobuf//:protoc",
        use_grpc_plugin = use_grpc_plugin,
        visibility = visibility,
        deps = cc_deps + ["@com_google_protobuf//:cc_wkt_protos"],
        protolib_deps = protolib_deps + ["@com_google_protobuf//:cc_wkt_protos"],
    )

def tf_proto_library_py(
        name,
        srcs = [],
        protodeps = [],
        deps = [],
        visibility = None,
        testonly = 0,
        srcs_version = "PY2AND3",
        use_grpc_plugin = False):
    py_deps = tf_deps(protodeps, "_py")
    py_name = name + "_py"
    if not srcs:
        # This is a collection of sub-libraries. Build header-only and impl
        # libraries containing all the sources.
        proto_gen(
            name = py_name + "_genproto",
            protoc = "@com_google_protobuf//:protoc",
            visibility = ["//visibility:public"],
            deps = [s + "_genproto" for s in py_deps],
        )
        native.py_library(
            name = py_name,
            deps = py_deps + ["@com_google_protobuf//:protobuf_python"],
            testonly = testonly,
            visibility = visibility,
        )
        return

    py_proto_library(
        name = py_name,
        testonly = testonly,
        srcs = srcs,
        default_runtime = "@com_google_protobuf//:protobuf_python",
        protoc = "@com_google_protobuf//:protoc",
        srcs_version = srcs_version,
        use_grpc_plugin = use_grpc_plugin,
        visibility = visibility,
        deps = deps + py_deps + ["@com_google_protobuf//:protobuf_python"],
    )

def tf_jspb_proto_library(**kwargs):
    pass

def tf_nano_proto_library(**kwargs):
    pass

def tf_proto_library(
        name,
        srcs = [],
        has_services = None,
        protodeps = [],
        visibility = None,
        testonly = 0,
        cc_libs = [],
        cc_api_version = 2,
        cc_grpc_version = None,
        j2objc_api_version = 1,
        js_codegen = "jspb",
        make_default_target_header_only = False,
        exports = []):
    """Make a proto library, possibly depending on other proto libraries."""
    _ignore = (js_codegen, exports)

    tf_proto_library_cc(
        name = name,
        testonly = testonly,
        srcs = srcs,
        cc_grpc_version = cc_grpc_version,
        cc_libs = cc_libs,
        make_default_target_header_only = make_default_target_header_only,
        protodeps = protodeps,
        visibility = visibility,
    )

    tf_proto_library_py(
        name = name,
        testonly = testonly,
        srcs = srcs,
        protodeps = protodeps,
        srcs_version = "PY2AND3",
        use_grpc_plugin = has_services,
        visibility = visibility,
    )

# A list of all files under platform matching the pattern in 'files'. In
# contrast with 'tf_platform_srcs' below, which seletive collects files that
# must be compiled in the 'default' platform, this is a list of all headers
# mentioned in the platform/* files.
def tf_platform_hdrs(files):
    return native.glob(["*/" + f for f in files])

def tf_platform_srcs(files):
    base_set = ["default/" + f for f in files]
    windows_set = base_set + ["windows/" + f for f in files]
    posix_set = base_set + ["posix/" + f for f in files]

    return select({
        "//tensorflow:windows": native.glob(windows_set),
        "//conditions:default": native.glob(posix_set),
    })

def tf_additional_lib_hdrs(exclude = []):
    windows_hdrs = native.glob([
        "default/*.h",
        "windows/*.h",
        "posix/error.h",
    ], exclude = exclude + [
        "default/subprocess.h",
        "default/posix_file_system.h",
    ])
    return select({
        "//tensorflow:windows": windows_hdrs,
        "//conditions:default": native.glob([
            "default/*.h",
            "posix/*.h",
        ], exclude = exclude),
    })

def tf_additional_lib_srcs(exclude = []):
    windows_srcs = native.glob([
        "default/*.cc",
        "windows/*.cc",
        "posix/error.cc",
    ], exclude = exclude + [
        "default/env.cc",
        "default/env_time.cc",
        "default/load_library.cc",
        "default/net.cc",
        "default/port.cc",
        "default/posix_file_system.cc",
        "default/subprocess.cc",
        "default/stacktrace_handler.cc",
    ])
    return select({
        "//tensorflow:windows": windows_srcs,
        "//conditions:default": native.glob([
            "default/*.cc",
            "posix/*.cc",
        ], exclude = exclude),
    })

def tf_additional_monitoring_hdrs():
    return []

def tf_additional_monitoring_srcs():
    return [
        "default/monitoring.cc",
    ]

def tf_additional_proto_hdrs():
    return [
        "default/integral_types.h",
        "default/logging.h",
    ]

def tf_additional_all_protos():
    return ["//tensorflow/core:protos_all"]

def tf_protos_all_impl():
    return [
        "//tensorflow/core:autotuning_proto_cc_impl",
        "//tensorflow/core:conv_autotuning_proto_cc_impl",
        "//tensorflow/core:protos_all_cc_impl",
    ]

def tf_protos_all():
    return if_static(
        extra_deps = tf_protos_all_impl(),
        otherwise = ["//tensorflow/core:protos_all_cc"],
    )

def tf_profiler_all_protos():
    return ["//tensorflow/core/profiler:protos_all"]

def tf_protos_grappler_impl():
    return ["//tensorflow/core/grappler/costs:op_performance_data_cc_impl"]

def tf_protos_grappler():
    return if_static(
        extra_deps = tf_protos_grappler_impl(),
        otherwise = ["//tensorflow/core/grappler/costs:op_performance_data_cc"],
    )

def tf_additional_device_tracer_srcs():
    return ["device_tracer.cc"]

def tf_additional_cupti_utils_cuda_deps():
    return []

def tf_additional_cupti_test_flags():
    return []

def tf_additional_rocdl_deps():
    return ["@local_config_rocm//rocm:rocm_headers"]

def tf_additional_rocdl_srcs():
    return ["default/rocm_rocdl_path.cc"]

def tf_additional_test_deps():
    return []

def tf_additional_test_srcs():
    return [
        "default/test.cc",
        "default/test_benchmark.cc",
    ]

def tf_kernel_tests_linkstatic():
    return 0

def tf_additional_lib_deps():
    """Additional dependencies needed to build TF libraries."""
    return [
        "@com_google_absl//absl/base:base",
        "@com_google_absl//absl/container:inlined_vector",
        "@com_google_absl//absl/types:span",
        "@com_google_absl//absl/types:optional",
    ] + if_static(
        ["@nsync//:nsync_cpp"],
        ["@nsync//:nsync_headers"],
    )

def tf_additional_core_deps():
    return select({
        "//tensorflow:android": [],
        "//tensorflow:ios": [],
        "//tensorflow:linux_s390x": [],
        "//tensorflow:windows": [],
        "//tensorflow:no_gcp_support": [],
        "//conditions:default": [
            "//tensorflow/core/platform/cloud:gcs_file_system",
        ],
    }) + select({
        "//tensorflow:android": [],
        "//tensorflow:ios": [],
        "//tensorflow:linux_s390x": [],
        "//tensorflow:windows": [],
        "//tensorflow:no_hdfs_support": [],
        "//conditions:default": [
            "//tensorflow/core/platform/hadoop:hadoop_file_system",
        ],
    }) + select({
        "//tensorflow:android": [],
        "//tensorflow:ios": [],
        "//tensorflow:linux_s390x": [],
        "//tensorflow:windows": [],
        "//tensorflow:no_aws_support": [],
        "//conditions:default": [
            "//tensorflow/core/platform/s3:s3_file_system",
        ],
    })

def tf_lib_proto_parsing_deps():
    return [
        ":protos_all_cc",
        "//third_party/eigen3",
        "//tensorflow/core/platform/default/build_config:proto_parsing",
    ]

def tf_py_clif_cc(name, visibility = None, **kwargs):
    pass

def tf_pyclif_proto_library(
        name,
        proto_lib,
        proto_srcfile = "",
        visibility = None,
        **kwargs):
    native.filegroup(name = name)
    native.filegroup(name = name + "_pb2")

def tf_additional_binary_deps():
    return ["@nsync//:nsync_cpp"] + if_cuda(
        [
            "//tensorflow/stream_executor:cuda_platform",
        ],
    ) + if_rocm(
        [
            "//tensorflow/stream_executor:rocm_platform",
            "//tensorflow/core/platform/default/build_config:rocm",
        ],
    ) + [
        # TODO(allenl): Split these out into their own shared objects (they are
        # here because they are shared between contrib/ op shared objects and
        # core).
        "//tensorflow/core/kernels:lookup_util",
        "//tensorflow/core/util/tensor_bundle",
    ] + if_mkl_ml(
        [
            "//third_party/mkl:intel_binary_blob",
        ],
    )

def tf_additional_rpc_deps():
    return []

def tf_additional_tensor_coding_deps():
    return []

def tf_fingerprint_deps():
    return [
        "@farmhash_archive//:farmhash",
    ]

def tf_protobuf_deps():
    return if_static(
        [
            "@com_google_protobuf//:protobuf",
        ],
        otherwise = ["@com_google_protobuf//:protobuf_headers"],
    )

def tf_protobuf_compiler_deps():
    return if_static(
        [
            "@com_google_protobuf//:protobuf",
        ],
        otherwise = ["@com_google_protobuf//:protobuf_headers"],
    )
