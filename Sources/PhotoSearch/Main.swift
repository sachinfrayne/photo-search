import Foundation

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains(where: { ["--index", "--search", "--labels", "--import"].contains($0) }) {
            Task { exit(await CLI.run(args)) }
            dispatchMain()
        }
        PhotoSearchApp.main()
    }
}
