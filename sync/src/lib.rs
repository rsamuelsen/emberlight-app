//! Emberlight sync core: reads the addon's SavedVariables, validates guild records and writes the
//! `Emberlight_Data` addon. Shared by the command-line tool and the future desktop launcher.

pub mod api;
pub mod auth;
pub mod datafile;
pub mod flow;
pub mod lua;
pub mod paths;
pub mod records;
pub mod update;
pub mod wow;
