use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

use fff_core::file_picker::FilePicker;
use fff_core::frecency::FrecencyTracker;
use fff_core::git::format_git_status;
use fff_core::grep::{self, GrepMode, GrepSearchOptions};
use fff_core::query_tracker::QueryTracker;
use fff_core::{
    FFFMode, FuzzySearchOptions, Location, PaginationArgs, QueryParser, SharedFrecency,
    SharedPicker, SharedQueryTracker,
};
use mimalloc::MiMalloc;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

struct App {
    picker: SharedPicker,
    frecency: SharedFrecency,
    query_tracker: SharedQueryTracker,
}

#[derive(Debug, Default)]
struct InitArgs {
    base_path: Option<String>,
    frecency_db_path: Option<String>,
    history_db_path: Option<String>,
    warmup_mmap_cache: bool,
    use_unsafe_no_lock: bool,
    ai_mode: bool,
}

#[derive(Debug, Deserialize)]
struct Request {
    id: u64,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Deserialize)]
struct SearchParams {
    query: String,
    max_threads: Option<usize>,
    current_file: Option<String>,
    combo_boost_multiplier: Option<i32>,
    min_combo_count: Option<u32>,
    page_index: Option<usize>,
    page_size: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct GrepParams {
    query: String,
    mode: Option<String>,
    max_file_size: Option<u64>,
    max_matches_per_file: Option<usize>,
    smart_case: Option<bool>,
    file_offset: Option<usize>,
    page_limit: Option<usize>,
    time_budget_ms: Option<u64>,
    before_context: Option<usize>,
    after_context: Option<usize>,
    classify_definitions: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct TrackQueryParams {
    query: String,
    path: String,
}

#[derive(Debug, Serialize)]
struct StatusPayload {
    base_path: String,
    indexed_files: usize,
    scanned_files_count: usize,
    is_scanning: bool,
}

#[derive(Debug, Serialize)]
struct RefreshGitPayload {
    updated_files_count: usize,
}

#[derive(Debug, Serialize)]
struct FileItemPayload {
    path: String,
    relative_path: String,
    file_name: String,
    size: u64,
    modified: u64,
    access_frecency_score: i64,
    modification_frecency_score: i64,
    total_frecency_score: i64,
    git_status: String,
    is_binary: bool,
}

#[derive(Debug, Serialize)]
struct SearchPayload {
    items: Vec<FileItemPayload>,
    total_matched: usize,
    total_files: usize,
    location: Option<LocationPayload>,
}

#[derive(Debug, Serialize)]
struct GrepMatchPayload {
    path: String,
    relative_path: String,
    file_name: String,
    git_status: String,
    size: u64,
    modified: u64,
    is_binary: bool,
    total_frecency_score: i64,
    access_frecency_score: i64,
    modification_frecency_score: i64,
    line_number: u64,
    col: usize,
    byte_offset: u64,
    line_content: String,
    fuzzy_score: Option<u16>,
    is_definition: bool,
    context_before: Vec<String>,
    context_after: Vec<String>,
}

#[derive(Debug, Serialize)]
struct GrepPayload {
    items: Vec<GrepMatchPayload>,
    total_matched: usize,
    total_files_searched: usize,
    total_files: usize,
    filtered_file_count: usize,
    next_file_offset: usize,
    regex_fallback_error: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum LocationPayload {
    #[serde(rename = "line")]
    Line { line: i32 },
    #[serde(rename = "position")]
    Position { line: i32, col: i32 },
    #[serde(rename = "range")]
    Range {
        start: PositionPayload,
        end: PositionPayload,
    },
}

#[derive(Debug, Serialize)]
struct PositionPayload {
    line: i32,
    col: i32,
}

impl LocationPayload {
    fn from_location(location: &Location) -> Self {
        match location {
            Location::Line(line) => Self::Line { line: *line },
            Location::Position { line, col } => Self::Position {
                line: *line,
                col: *col,
            },
            Location::Range { start, end } => Self::Range {
                start: PositionPayload {
                    line: start.0,
                    col: start.1,
                },
                end: PositionPayload {
                    line: end.0,
                    col: end.1,
                },
            },
        }
    }
}

impl FileItemPayload {
    fn from_item(item: &fff_core::FileItem) -> Self {
        Self {
            path: item.path.to_string_lossy().to_string(),
            relative_path: item.relative_path.clone(),
            file_name: item.file_name.clone(),
            size: item.size,
            modified: item.modified,
            access_frecency_score: item.access_frecency_score,
            modification_frecency_score: item.modification_frecency_score,
            total_frecency_score: item.total_frecency_score,
            git_status: format_git_status(item.git_status).to_string(),
            is_binary: item.is_binary,
        }
    }
}

impl GrepMatchPayload {
    fn from_match(matched: &fff_core::GrepMatch, file: &fff_core::FileItem) -> Self {
        Self {
            path: file.path.to_string_lossy().to_string(),
            relative_path: file.relative_path.clone(),
            file_name: file.file_name.clone(),
            git_status: format_git_status(file.git_status).to_string(),
            size: file.size,
            modified: file.modified,
            is_binary: file.is_binary,
            total_frecency_score: file.total_frecency_score,
            access_frecency_score: file.access_frecency_score,
            modification_frecency_score: file.modification_frecency_score,
            line_number: matched.line_number,
            col: matched.col,
            byte_offset: matched.byte_offset,
            line_content: matched.line_content.clone(),
            fuzzy_score: matched.fuzzy_score,
            is_definition: matched.is_definition,
            context_before: matched.context_before.clone(),
            context_after: matched.context_after.clone(),
        }
    }
}

impl App {
    fn new(args: InitArgs) -> Result<Self, String> {
        let base_path = args
            .base_path
            .ok_or_else(|| "missing required argument --base-path".to_string())?;
        let base_path = fff_core::path_utils::canonicalize(PathBuf::from(base_path))
            .map_err(|error| format!("failed to canonicalize base path: {error}"))?;

        let picker: SharedPicker = Arc::new(RwLock::new(None));
        let frecency: SharedFrecency = Arc::new(RwLock::new(None));
        let query_tracker: SharedQueryTracker = Arc::new(RwLock::new(None));

        if let Some(path) = args.frecency_db_path {
            ensure_parent_dir(&path)?;
            let tracker = FrecencyTracker::new(&path, args.use_unsafe_no_lock)
                .map_err(|error| format!("failed to initialize frecency database: {error}"))?;
            {
                let mut guard = frecency
                    .write()
                    .map_err(|error| format!("failed to acquire frecency lock: {error}"))?;
                *guard = Some(tracker);
            }
            FrecencyTracker::spawn_gc(Arc::clone(&frecency), path, args.use_unsafe_no_lock);
        }

        if let Some(path) = args.history_db_path {
            ensure_parent_dir(&path)?;
            let tracker = QueryTracker::new(&path, args.use_unsafe_no_lock)
                .map_err(|error| format!("failed to initialize query history database: {error}"))?;
            let mut guard = query_tracker
                .write()
                .map_err(|error| format!("failed to acquire query tracker lock: {error}"))?;
            *guard = Some(tracker);
        }

        let mode = if args.ai_mode {
            FFFMode::Ai
        } else {
            FFFMode::Neovim
        };

        FilePicker::new_with_shared_state(
            base_path.to_string_lossy().to_string(),
            args.warmup_mmap_cache,
            mode,
            Arc::clone(&picker),
            Arc::clone(&frecency),
        )
        .map_err(|error| format!("failed to initialize file picker: {error}"))?;

        Ok(Self {
            picker,
            frecency,
            query_tracker,
        })
    }

    fn cleanup(&self) {
        if let Ok(mut guard) = self.picker.write()
            && let Some(ref mut picker) = *guard
        {
            picker.stop_background_monitor();
        }
    }

    fn status(&self) -> Result<StatusPayload, String> {
        let guard = self
            .picker
            .read()
            .map_err(|error| format!("failed to acquire picker lock: {error}"))?;
        let picker = guard
            .as_ref()
            .ok_or_else(|| "file picker is not initialized".to_string())?;
        let progress = picker.get_scan_progress();

        Ok(StatusPayload {
            base_path: picker.base_path().to_string_lossy().to_string(),
            indexed_files: picker.get_files().len(),
            scanned_files_count: progress.scanned_files_count,
            is_scanning: progress.is_scanning,
        })
    }

    fn search(&self, params: SearchParams) -> Result<SearchPayload, String> {
        let picker_guard = self
            .picker
            .read()
            .map_err(|error| format!("failed to acquire picker lock: {error}"))?;
        let picker = picker_guard
            .as_ref()
            .ok_or_else(|| "file picker is not initialized".to_string())?;

        let base_path = picker.base_path().to_path_buf();
        let min_combo_count = params.min_combo_count.unwrap_or(3);
        let last_same_query_entry = {
            let guard = self
                .query_tracker
                .read()
                .map_err(|error| format!("failed to acquire query tracker lock: {error}"))?;

            guard
                .as_ref()
                .map(|tracker| {
                    tracker.get_last_query_entry(&params.query, &base_path, min_combo_count)
                })
                .transpose()
                .map_err(|error| format!("failed to read query history: {error}"))?
                .flatten()
        };

        let parsed = QueryParser::default().parse(&params.query);
        let result = FilePicker::fuzzy_search(
            picker.get_files(),
            &params.query,
            parsed,
            FuzzySearchOptions {
                max_threads: params.max_threads.unwrap_or(0),
                current_file: params.current_file.as_deref(),
                project_path: Some(picker.base_path()),
                last_same_query_match: last_same_query_entry.as_ref(),
                combo_boost_score_multiplier: params.combo_boost_multiplier.unwrap_or(100),
                min_combo_count,
                pagination: PaginationArgs {
                    offset: params.page_index.unwrap_or(0),
                    limit: params.page_size.unwrap_or(100),
                },
            },
        );

        Ok(SearchPayload {
            items: result
                .items
                .iter()
                .map(|item| FileItemPayload::from_item(item))
                .collect(),
            total_matched: result.total_matched,
            total_files: result.total_files,
            location: result.location.as_ref().map(LocationPayload::from_location),
        })
    }

    fn grep(&self, params: GrepParams) -> Result<GrepPayload, String> {
        let picker_guard = self
            .picker
            .read()
            .map_err(|error| format!("failed to acquire picker lock: {error}"))?;
        let picker = picker_guard
            .as_ref()
            .ok_or_else(|| "file picker is not initialized".to_string())?;

        let mode = match params.mode.as_deref() {
            Some("regex") => GrepMode::Regex,
            Some("fuzzy") => GrepMode::Fuzzy,
            _ => GrepMode::PlainText,
        };

        let parsed = if picker.mode().is_ai() {
            QueryParser::new(fff_query_parser::AiGrepConfig).parse(&params.query)
        } else {
            grep::parse_grep_query(&params.query)
        };

        let result = grep::grep_search(
            picker.get_files(),
            &params.query,
            parsed.as_ref(),
            &GrepSearchOptions {
                max_file_size: params.max_file_size.unwrap_or(10 * 1024 * 1024),
                max_matches_per_file: params.max_matches_per_file.unwrap_or(0),
                smart_case: params.smart_case.unwrap_or(true),
                file_offset: params.file_offset.unwrap_or(0),
                page_limit: params.page_limit.unwrap_or(100),
                mode,
                time_budget_ms: params.time_budget_ms.unwrap_or(0),
                before_context: params.before_context.unwrap_or(0),
                after_context: params.after_context.unwrap_or(0),
                classify_definitions: params.classify_definitions.unwrap_or(false),
            },
        );

        Ok(GrepPayload {
            items: result
                .matches
                .iter()
                .map(|matched| {
                    let file = result.files[matched.file_index];
                    GrepMatchPayload::from_match(matched, file)
                })
                .collect(),
            total_matched: result.matches.len(),
            total_files_searched: result.total_files_searched,
            total_files: result.total_files,
            filtered_file_count: result.filtered_file_count,
            next_file_offset: result.next_file_offset,
            regex_fallback_error: result.regex_fallback_error,
        })
    }

    fn rescan(&self) -> Result<Value, String> {
        let mut guard = self
            .picker
            .write()
            .map_err(|error| format!("failed to acquire picker lock: {error}"))?;
        let picker = guard
            .as_mut()
            .ok_or_else(|| "file picker is not initialized".to_string())?;

        picker
            .trigger_rescan(&self.frecency)
            .map_err(|error| format!("failed to trigger rescan: {error}"))?;

        Ok(json!({ "queued": true }))
    }

    fn refresh_git_status(&self) -> Result<RefreshGitPayload, String> {
        let updated_files_count = FilePicker::refresh_git_status(&self.picker, &self.frecency)
            .map_err(|error| format!("failed to refresh git status: {error}"))?;

        Ok(RefreshGitPayload { updated_files_count })
    }

    fn track_query(&self, params: TrackQueryParams) -> Result<Value, String> {
        let file_path = fff_core::path_utils::canonicalize(Path::new(&params.path))
            .map_err(|error| format!("failed to canonicalize file path: {error}"))?;

        let project_path = {
            let guard = self
                .picker
                .read()
                .map_err(|error| format!("failed to acquire picker lock: {error}"))?;
            let picker = guard
                .as_ref()
                .ok_or_else(|| "file picker is not initialized".to_string())?;
            picker.base_path().to_path_buf()
        };

        let mut guard = self
            .query_tracker
            .write()
            .map_err(|error| format!("failed to acquire query tracker lock: {error}"))?;
        if let Some(ref mut tracker) = *guard {
            tracker
                .track_query_completion(&params.query, &project_path, &file_path)
                .map_err(|error| format!("failed to track query completion: {error}"))?;
        }

        Ok(json!({ "tracked": true }))
    }
}

impl Drop for App {
    fn drop(&mut self) {
        self.cleanup();
    }
}

fn ensure_parent_dir(path: &str) -> Result<(), String> {
    let Some(parent) = Path::new(path).parent() else {
        return Ok(());
    };

    std::fs::create_dir_all(parent)
        .map_err(|error| format!("failed to create directory '{}': {error}", parent.display()))
}

fn parse_args() -> Result<InitArgs, String> {
    let mut args = std::env::args().skip(1);
    let mut init = InitArgs::default();

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--base-path" => init.base_path = Some(next_arg(&mut args, &arg)?),
            "--frecency-db-path" => init.frecency_db_path = Some(next_arg(&mut args, &arg)?),
            "--history-db-path" => init.history_db_path = Some(next_arg(&mut args, &arg)?),
            "--warmup-mmap-cache" => init.warmup_mmap_cache = true,
            "--use-unsafe-no-lock" => init.use_unsafe_no_lock = true,
            "--ai-mode" => init.ai_mode = true,
            "--help" | "-h" => return Err(help_text()),
            other => return Err(format!("unknown argument: {other}\n\n{}", help_text())),
        }
    }

    if init.base_path.is_none() {
        return Err(format!(
            "missing required argument --base-path\n\n{}",
            help_text()
        ));
    }

    Ok(init)
}

fn next_arg(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    args.next()
        .ok_or_else(|| format!("missing value for {flag}\n\n{}", help_text()))
}

fn help_text() -> String {
    [
        "Usage: fff-emacs --base-path PATH [options]",
        "",
        "Options:",
        "  --base-path PATH           Root directory to index",
        "  --frecency-db-path PATH    Frecency database path",
        "  --history-db-path PATH     Query history database path",
        "  --warmup-mmap-cache        Warm mmap cache after scan",
        "  --use-unsafe-no-lock       Disable LMDB file locking",
        "  --ai-mode                  Use AI-oriented grep parsing",
    ]
    .join("\n")
}

fn write_json_line(output: &mut impl Write, value: &impl Serialize) -> Result<(), String> {
    serde_json::to_writer(&mut *output, value)
        .map_err(|error| format!("failed to serialize response: {error}"))?;
    output
        .write_all(b"\n")
        .map_err(|error| format!("failed to write response: {error}"))?;
    output
        .flush()
        .map_err(|error| format!("failed to flush response: {error}"))
}

fn dispatch(app: &App, request: Request) -> Result<Option<Value>, String> {
    match request.method.as_str() {
        "status" => serde_json::to_value(app.status()?)
            .map(Some)
            .map_err(|error| format!("failed to serialize status payload: {error}")),
        "search" => serde_json::to_value(app.search(from_value(request.params)?)?)
            .map(Some)
            .map_err(|error| format!("failed to serialize search payload: {error}")),
        "grep" => serde_json::to_value(app.grep(from_value(request.params)?)?)
            .map(Some)
            .map_err(|error| format!("failed to serialize grep payload: {error}")),
        "rescan" => Ok(Some(app.rescan()?)),
        "refresh_git_status" => serde_json::to_value(app.refresh_git_status()?)
            .map(Some)
            .map_err(|error| format!("failed to serialize git payload: {error}")),
        "track_query" => Ok(Some(app.track_query(from_value(request.params)?)?)),
        "shutdown" => Ok(None),
        other => Err(format!("unknown method: {other}")),
    }
}

fn from_value<T: for<'de> Deserialize<'de>>(value: Value) -> Result<T, String> {
    serde_json::from_value(value).map_err(|error| format!("invalid request parameters: {error}"))
}

fn main() {
    let args = match parse_args() {
        Ok(args) => args,
        Err(error) => {
            eprintln!("fff-emacs: {error}");
            std::process::exit(2);
        }
    };

    let app = match App::new(args) {
        Ok(app) => app,
        Err(error) => {
            eprintln!("fff-emacs: {error}");
            std::process::exit(1);
        }
    };

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut output = stdout.lock();

    if let Err(error) = write_json_line(&mut output, &json!({ "event": "ready" })) {
        eprintln!("fff-emacs: {error}");
        std::process::exit(1);
    }

    for line_result in stdin.lock().lines() {
        let line = match line_result {
            Ok(line) => line,
            Err(error) => {
                eprintln!("fff-emacs: failed to read request: {error}");
                break;
            }
        };

        if line.trim().is_empty() {
            continue;
        }

        let request: Request = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(error) => {
                let _ = write_json_line(
                    &mut output,
                    &json!({
                        "id": Value::Null,
                        "ok": false,
                        "error": format!("invalid request: {error}"),
                    }),
                );
                continue;
            }
        };

        let request_id = request.id;
        let response = match dispatch(&app, request) {
            Ok(Some(result)) => json!({
                "id": request_id,
                "ok": true,
                "result": result,
            }),
            Ok(None) => {
                let _ = write_json_line(
                    &mut output,
                    &json!({
                        "id": request_id,
                        "ok": true,
                        "result": { "shutdown": true },
                    }),
                );
                break;
            }
            Err(error) => json!({
                "id": request_id,
                "ok": false,
                "error": error,
            }),
        };

        if let Err(error) = write_json_line(&mut output, &response) {
            eprintln!("fff-emacs: {error}");
            break;
        }
    }
}
