use axum::extract::State;
use axum::response::{Html, IntoResponse, Response};

use crate::state::AppState;

const DASHBOARD_HTML: &str = include_str!("../templates/dashboard.html");

/// GET / — HTMX dashboard
pub async fn dashboard(State(_state): State<AppState>) -> Response {
    Html(DASHBOARD_HTML).into_response()
}
