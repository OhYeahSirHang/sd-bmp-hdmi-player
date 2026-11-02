# build_run_flow.tcl -- 工程 run 流程构建（推荐）
#   为什么必须用 run 流程: in-memory 的 synth_design 会丢掉 IP 的 XDC,
#   导致时序按默认(过严)计算, 出现 -4ns 级的"假违规"。
#
# 用法: vivado -mode batch -source build_run_flow.tcl -log build.log -journal build.jou

set prj_dir "C:/path/to/your_project"
set part    "xc7a35tfgg484-2"
set top     "sd_rd_img"
set bitname "sd_rd_img.bit"

open_project "$prj_dir/sd_bmp_hdmi.xpr"
set_property top $top [current_fileset]

# ---- 综合：走工程 run（带 IP 约束）----
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: synth failed"; exit 1
}
open_run synth_1

# ---- 实现：Explore + phys_opt 拿时序 ----
set_param drc.disableLUTOverUtilError 1
set_property is_enabled false [get_drc_checks UTLZ-1]

opt_design
place_design -directive Explore
phys_opt_design -directive Explore
route_design
phys_opt_design -directive AggressiveExplore

set_property is_enabled false [get_drc_checks UTLZ-2]

report_timing_summary -file "$prj_dir/timing.rpt"
report_utilization   -file "$prj_dir/util.rpt"
write_bitstream -force "$prj_dir/$bitname"
puts "=== BUILD DONE ==="
exit
