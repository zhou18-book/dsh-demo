/// Shown in the app so a sideloaded build can be identified.
///
/// Deliberately a plain constant rather than a package_info_plus lookup: the whole
/// point is to let someone holding two APKs with identical-looking filenames tell
/// which build is installed, and adding a plugin for one string is not worth it.
///
/// KEEP IN SYNC with `version:` in pubspec.yaml.
const String appVersion = '1.0.1';
