import Foundation

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--models"] {
            // Lists the model folders PhotoSearch can see; needs no database.
            let current = AppConfig.load().searchModel ?? ModelManifest.defaultID
            for m in ModelManifest.discover() {
                print("\(m.id == current ? "*" : " ") \(m.id)  \(m.displayName)  \(m.dimensions) dims  \(m.license ?? "")  [\(m.folder?.path ?? "")]")
            }
            exit(0)
        }
        if args.contains(where: { ["--index", "--search", "--compare", "--tokens", "--labels", "--import"].contains($0) }) {
            Task { exit(await CLI.run(args)) }
            dispatchMain()
        }
        PhotoSearchApp.main()
    }
}
