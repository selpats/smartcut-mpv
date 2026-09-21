#![windows_subsystem = "windows"]

use std::env;
use std::fs::File;
use std::io::Read;
use std::os::windows::io::FromRawHandle;
use std::ptr;
use arboard::Clipboard;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn CreateNamedPipeA(
        lpName: *const u8,
        dwOpenMode: u32,
        dwPipeMode: u32,
        nMaxInstances: u32,
        nOutBufferSize: u32,
        nInBufferSize: u32,
        nDefaultTimeOut: u32,
        lpSecurityAttributes: *mut std::ffi::c_void,
    ) -> *mut std::ffi::c_void;
    fn ConnectNamedPipe(hNamedPipe: *mut std::ffi::c_void, lpOverlapped: *mut std::ffi::c_void) -> i32;
}

const PIPE_ACCESS_INBOUND: u32 = 0x00000001;
const PIPE_TYPE_BYTE: u32 = 0x00000000;
const PIPE_READMODE_BYTE: u32 = 0x00000000;
const PIPE_WAIT: u32 = 0x00000000;
const INVALID_HANDLE_VALUE: *mut std::ffi::c_void = -1isize as *mut std::ffi::c_void;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        return;
    }
    let path = &args[1];
    let flag_file = args.get(2);
    let crop_rect: Option<(u32, u32, u32, u32)> = if args.len() >= 7 {
        let x = args[3].parse::<u32>().ok();
        let y = args[4].parse::<u32>().ok();
        let w = args[5].parse::<u32>().ok();
        let h = args[6].parse::<u32>().ok();
        match (x, y, w, h) {
            (Some(x), Some(y), Some(w), Some(h)) if w > 0 && h > 0 => Some((x, y, w, h)),
            _ => None,
        }
    } else {
        None
    };
    let mut buffer = Vec::new();
    
    if path.starts_with(r"\\.\pipe\") {
        let mut path_nul = path.clone();
        path_nul.push('\0');
        let handle = unsafe {
            CreateNamedPipeA(
                path_nul.as_ptr(),
                PIPE_ACCESS_INBOUND,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                1,
                0,
                1024 * 1024 * 30,
                0,
                ptr::null_mut(),
            )
        };
        
        if handle == INVALID_HANDLE_VALUE {
            return;
        }
        
        if let Some(flag) = flag_file {
            let _ = File::create(flag);
        }
        
        unsafe { ConnectNamedPipe(handle, ptr::null_mut()) };
        let mut file = unsafe { File::from_raw_handle(handle as _) };
        let _ = file.read_to_end(&mut buffer);
    } else {
        if let Ok(mut file) = File::open(path) {
            let _ = file.read_to_end(&mut buffer);
            let _ = std::fs::remove_file(path);
        }
    }
    
    if buffer.is_empty() { return; }
    
    if let Ok(img) = image::load_from_memory(&buffer) {
        let img = if let Some((x, y, w, h)) = crop_rect {
            use image::GenericImageView;
            let (orig_w, orig_h) = img.dimensions();
            let cx = x.min(orig_w);
            let cy = y.min(orig_h);
            let cw = w.min(orig_w.saturating_sub(cx));
            let ch = h.min(orig_h.saturating_sub(cy));
            if cw > 0 && ch > 0 {
                img.crop_imm(cx, cy, cw, ch)
            } else {
                img
            }
        } else {
            img
        };
        let rgba = img.to_rgba8();
        let (width, height) = rgba.dimensions();
        
        if let Ok(mut ctx) = Clipboard::new() {
            let img_data = arboard::ImageData {
                width: width as usize,
                height: height as usize,
                bytes: std::borrow::Cow::Borrowed(rgba.as_raw()),
            };
            let _ = ctx.set_image(img_data);
        }
    }
}
