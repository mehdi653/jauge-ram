import Foundation

/// Texte de l'interface dans la langue du système.
///
/// La clé est le texte français lui-même : c'est la langue source, et `fr.lproj` reste
/// vide. `en.lproj/Localizable.strings` donne l'anglais, qui sert aussi pour toute autre
/// langue (CFBundleDevelopmentRegion = en, voir build.sh).
///
/// Avec des arguments, la clé est un format : %@ pour un texte, %lld pour un Int, %d pour
/// un Int32, et %% pour un « % » littéral. Hors du bundle .app (binaire lancé seul), il
/// n'y a pas de traduction : la clé, en français, s'affiche telle quelle.
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    translate(key, arguments)
}

/// Variante pour un nombre : `one` quand il vaut 1, où le « 1 » est écrit dans la clé ;
/// `other` sinon, qui reçoit le nombre en premier argument (%lld), avant `arguments`.
/// Les nombres affichés ne valent jamais 0 (la ligne n'apparaît pas), ce qui convient au
/// français comme à l'anglais.
func tr(count: Int, one: String, other: String, _ arguments: CVarArg...) -> String {
    count == 1 ? translate(one, arguments) : translate(other, [count as CVarArg] + arguments)
}

/// Sans locale : tailles et pourcentages arrivent déjà mis en forme par formatBytes et
/// formatShare ; avec la locale, un pid deviendrait « 41 529 ».
private func translate(_ key: String, _ arguments: [CVarArg]) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, arguments: arguments)
}
