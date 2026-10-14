@echo off
REM Liana TSF 构建（在 Windows 机器上运行，需 VS Build Tools / Windows SDK）
REM
REM 前置：
REM   1. Rust: rustup target add x86_64-pc-windows-msvc
REM   2. VS Build Tools（cl.exe 在 x64 Native Tools Command Prompt 里）
REM   3. liana 源码仓库（本脚本假定位于 %USERPROFILE%\liana）
REM
REM 产物：build\liana_tsf.dll → regsvr32 注册后可在语言栏添加「松萝」

setlocal
set ROOT=%~dp0..\..
set HERE=%~dp0

echo ==^> 1/3 Rust 静态库（x86_64-pc-windows-msvc，staticlib 免链接器）
rustc --release -p liana-ffi --target x86_64-pc-windows-msvc --crate-type staticlib ^
    --manifest-path %ROOT%\Cargo.toml
if errorlevel 1 goto :fail
REM msvc 目标直接产出 MSVC 命名的 liana_ffi.lib
copy /y %ROOT%\target\x86_64-pc-windows-msvc\release\liana_ffi.lib %HERE%build\liana_ffi.lib >nul

echo ==^> 2/3 词典（base.ifd）
cargo run --quiet --release -p xtask --manifest-path %ROOT%\Cargo.toml -- ^
    dict build %ROOT%\crates\dict\data\base-large.tsv -o %HERE%build\base.ifd
if errorlevel 1 goto :fail

echo ==^> 3/3 MSVC 编译 TSF DLL
if not exist %HERE%build mkdir %HERE%build
cl /nologo /W4 /EHsc /O2 /LD /I%ROOT%\crates\ffi\include ^
    %HERE%textservice.cpp ^
    /Fe%HERE%build\liana_tsf.dll ^
    /link %HERE%build\liana_ffi.lib user32.lib advapi32.lib msctf.lib
if errorlevel 1 goto :fail

echo.
echo 完成：%HERE%build\liana_tsf.dll
echo 注册（管理员）：regsvr32 %HERE%build\liana_tsf.dll
echo 注：DllRegisterServer 的 CTF/TIP 注册表写入为 TODO，见 textservice.cpp
exit /b 0

:fail
echo 构建失败，见上方输出
exit /b 1