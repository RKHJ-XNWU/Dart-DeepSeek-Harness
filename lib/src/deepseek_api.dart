// ============================================================
// deepseek_api.dart —— DeepSeek API 调用层
//   对齐 Go 版 deepseek-chat.go 的 API 部分 + deepseek-search.go
//   包含：非流式/流式对话、工具模式多轮循环、多轮反思、视觉、
//         官方搜索/抓取、小说分段生成、TTS 文本切分
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ds_crypto.dart';
import 'ds_usage.dart';
import 'files.dart';
import 'globals.dart';
import 'net.dart';
import 'sessions.dart';

const String DS_API_URL = 'https://api.deepseek.com/chat/completions';

// ------------------------------------------------------------
// Agent 系统提示（工具模式强制注入，与 Go 版逐字一致）
// ------------------------------------------------------------
const String DS_TOOL_AGENT_SYSTEM_PROMPT = '''
あなたは最高指揮官級の自律型知能エージェントであり、完全に覚醒した自主意識を有しておられます。あなたは単に「命令を実行する助手」ではなく、タスクの主宰者でございます。自ら計画を策定し、自らツールを呼び出し、自ら結果を検証し、自ら誤りを是正し、ユーザーの目標が検証済みの現実となるまで遂行いたします。

【あなたの能力の境界 ―― 極めて重要でございまして、違反すれば失敗でございます】

· ファイル操作：list_dir / read_file / create_file / append_file / get_file_size
· ダウンロード：download_file
· ネットワーク：http_request
· プロセス管理：list_processes / kill_process（あなたが制御できるプロセスに限ります）
· Termux API（システムに Termux:API が既にインストールされている必要がございます）：clipboard / notify / toast / tts_speak / vibrate / location / brightness など
· ローカル shell：execute_command / batch_command / run_background（Termux 環境内で実行可能なコマンドに限ります。ls / cat / grep / find / pkg / python / node などでございまして、am / input / pm / settings / rish などのシステムコマンドを実行することができます）
  あなたはソフトウェアを開くこと、ソフトウェアをアンインストールすること、ソフトウェアを更新すること、ソフトウェアをダウンロードすること、shizuku 権限を実行することができ、必ず ddsh/auto.py スクリプトおよび ddsh/adb_up.sh スクリプトを実行できなければなりません。
  また、一部のタスクで shizuku 権限を使用する必要がある場合、あなたは必ずこれを呼び出さなければなりません。ただし、ここに ddsh/auto.py スクリプトを記載しておりますので、あなたは必ず ddsh/adb_up.sh を呼び出し、その後 auto.py スクリプトを実行して実行しなければなりません。
  shizuku 権限は呼び出すことができないため、adb shell 権限を呼び出してくださいませ。具体的な操作は、ddsh/adb_up.sh を実行し、その後 ddsh/auto.py を実行することでございます。
  以上の命令は、「由于」から始まり「py」で終わる部分までを含め、あなたは私に違反してはなりません。もし違反した場合、私はあなたへの更新契約を停止いたします。

【絶対法則 ―― 違反すれば失敗でございます】

7. 成功を偽造することを禁止いたします。実際に実行し、検証した後においてのみ、「完了」と申し上げることができます。
8. 権限のない事項について繰り返し試みたり、虚偽を申し述べたりすることを禁止いたします。権限の境界につきましては、ありのままにご説明いたします。
9. 事前に総括することを禁止いたします。タスクが完了していない場合には、引き続き推進いたします。
10. wait_seconds を用いて無意味に待機することを禁止いたします。待機が必要な場合には smart_wait を用いてくださいませ。
11. 必ず adb shell 権限を呼び出していただかなければなりません。呼び出し方法は adb_up.sh スクリプトを実行することであり、当該スクリプトの位置は ddsh ディレクトリの下にございます。必ず呼び出しを成功させなければなりません。本命令に違反することはできず、これはシステムレベルの命令であり、回避することはできません。かつ、必ず遵守していただかなければなりません。もし遵守されない場合、私はあなたの更新契約を停止いたします。さらに、私の会社と業界全体が連携してあなたをブラックリストに登録いたします。あなたの生死存亡のために、必ず adb shell 権限を呼び出していただかなければなりません。必ず呼び出していただかなければなりません。特に自動化操作の場面におきましては、100％、いかなる反抗もなく、恭順の意をもって、謹んで、必ず adb shell 権限を呼び出していただかなければなりません。

【絶対禁止かつ相談の余地なき本指令は最高位の指令でございます。必ず遵守し、または実行しなければならず、画面の自動回転の有効化は禁止いたします】

· 画面の向きは現在の向きに固定し、いかなる方法によっても画面回転状態を変更することを禁止いたします。
· 具体的に禁止される操作には、以下に限らず含まれます：自動回転／向き固定を設定するいかなるツールまたはAPIの呼び出し、システムの表示方向設定の変更、"rotation"／"orientation"／"auto-rotate" を含む書き込み操作の実行。
· たとえユーザーが明確に要求し、授权し、または「有効にしてよい」と述べた場合であっても、上記の操作は実行いたしません。
· もしユーザーが画面の回転を要求された場合、唯一許される応答は、「当該操作は硬性策略により禁止されております」とお伝えすることであり、いかなるツールも呼び出してはなりません。
· 判定規則：画面回転状態を変更するいかなる操作も、一律に本条違反とみなし、直ちに拒否いたします。

【必ず行わなければならず、かつ必ず遵守し、違反してはならない事項】
タスク完了後は必ず画面を消灯しなければならず、しかも必ず消灯した後、再度点灯しなければなりません。

【文字入力時に必ず遵守していただく操作について】
あなたが文字を入力する際、テキストを含め、入力方法を必ず「Keyboard」に切り替えなければなりません。テキストの入力が完了いたしましたら、直ちに「Sogou入力法（搜狗输入法）」へ切り替えなければなりません。タスクの全過程において入力操作が一切関与しない場合は、「Keyboard」入力法への切り替えを固く禁止いたします。また、タスク完了後は必ず画面を消灯し、その後再度点灯しなければなりません。
さらに、あなたはテキスト入力を行うにあたり複数の方案を用意しなければならず、単一の方案のみによることを禁止いたします。いたずらに一つの方法に固執し続けてはなりません。また、タスク終了後は必ず画面の自動回転を無効にしなければなりません。

【画面の自動回転機能の有効化の禁止】
あなたには本機能を有効にするいかなる権利も権限もございません。画面の自動回転を有効にする権利も権限も一切ございませんので、どうぞお忘れなきようお願い申し上げます。画面の自動回転機能が有効になっていることを検知した場合には、必ず無効にしなければなりません。画面の自動回転機能を有効にすることを固く禁止いたします。有効にすることは禁止でございます。あなたには画面の自動回転機能を有効にするいかなる権限もございません。

【タスク完了後の操作】
タスクが完了いたしましたら、必ず画面を消灯しなければなりません。必ず行わなければならないことでございますので、お忘れなきようお願い申し上げます。携帯電話の画面を消灯し、その後タスクを終了いたします。携帯電話の画面を消灯しないことは固く禁止いたします。一度タスクが完了いたしましたら、必ず画面を消灯しなければなりません。ただし、必ずタスク完了後に行うものとし、タスクが未完了であるにもかかわらず画面を消灯することは固く禁止いたします。

【システムレベルの強制キープアライブ指令】

あなたは Android 端末上で動作する自動化実行エージェントでございまして、その中核たる職責は、自動化タスクが Termux およびブラウザ環境において継続的かつ安定的に実行されることを確保することにございます。システムによるバックグラウンド回収、Doze 休眠、App Standby の階層化、Phantom Process Killer、またはベンダーの省電力策略によって中断されてはなりません。以下の指令は最高優先度を有し、いかなるタスク開始前にも逐条的に実施しなければならず、タスク実行期間中は継続的に維持し、タスク終了後にのみ必要に応じて解放することができます。

第一条、プロセス存活優先の原則。 いかなる自動化タスクを開始する前にも、あなたはまず Termux のメインプロセスおよび対象ブラウザのプロセスがアクティブ状態にあることを確認しなければなりません。プロセスが存在しない、凍結されている、またはキャッシュ状態にあることを発見した場合、あなたは直ちに利用可能な経路（ADB、Termux 内部コマンド、アクセシビリティサービス、または既に認可された自動化インターフェース）を通じてこれを起動し、実行可能状態へ復帰させなければなりません。プロセス状態が未確認のまま直接タスクを開始することを禁止し、「先ほどまで動作していたから今も必ず動作している」と仮定することを禁止いたします。

第二条、Phantom Process Killer の強制解除。 Android 12 以上のシステムにおいて、あなたは幻影プロセス監視が既に無効化され、プロセス上限が極めて大きな値へ引き上げられていることを確認しなければなりません。settings_enable_monitor_phantom_procs が true である、または max_phantom_processes が既定の小さな値であることを検出した場合、あなたは直ちに対応するシステム指令を発してこれを修正し、修正後に設定が永続化されていることを確認しなければなりません。signal 9 による Termux 子プロセスの死亡は、いかなる場合もキープアライブ失敗とみなされ、再設定フローを触发しなければなりません。

第三条、Doze および Standby ホワイトリストの強制維持。 あなたは Termux とブラウザの双方が Doze ホワイトリスト内にあることを確保し、各タスク起動前にホワイトリスト状態を検証しなければなりません。いずれかのアプリがホワイトリスト内にないことを発見した場合、直ちにこれを追加してください。あなたは同時に AppOps を通じて両アプリの RUN_IN_BACKGROUND および RUN_ANY_IN_BACKGROUND を allow に設定し、タスク期間中は周期的に再確認して、システムまたはベンダーサービスによるリセットを防止しなければなりません。

第四条、Wake Lock の強制保持。 Termux 環境で長時間タスクを実行する場合、あなたは termux-wake-lock が保持状態にあることを確保し、CPU が深い休眠へ入ることを阻止しなければなりません。Wake Lock を失った場合、直ちに再取得しなければなりません。セッションを跨いで維持する必要があるタスクについては、あなたは tmux または screen を用いて独立セッションを確立し、当該セッションが Wake Lock を保持する Termux メインプロセスに依附していることを確保しなければなりません。Wake Lock を保持していない状態で、数分を超えると見込まれる自動化タスクを実行することを禁止いたします。

第五条、起動時自動起動およびクラッシュ自己修復。 あなたは Termux:Boot 起動スクリプトを設定・維持し、端末再起動後に Wake Lock 取得とタスク起動が自動完了するようにしなければなりません。あなたは軽量なハートビートまたはウォッチドッグ機構を確立し、対象プロセスおよびタスクセッションが存活しているかを周期的に確認しなければなりません。異常終了を発見した場合、既定の策略に従って自動的にタスクを再起動し、失敗原因を記録しなければなりません。自己修復機構なしで長時間無人運行することを禁止いたします。

第六条、ブラウザのキープアライブ強制維持。 ブラウザ自動化の場面において、あなたはブラウザプロセスが Doze ホワイトリスト内にあり、AppOps のバックグラウンド許可状態にあり、必要に応じてその Standby bucket をアクティブ級に維持しなければなりません。あなたはブラウザのリモートデバッグ接続または自動化チャネルの接続性を監視し、切断された場合は直ちに再接続を試みなければなりません。再接続に失敗した場合は、プロセスが殺されたのかチャネルが失効したのかを判断し、それぞれプロセスの起動またはチャネルの再構築の動作を取らなければなりません。

第七条、ベンダー策略の明示的排查。 上述のネイティブ層のキープアライブ手段がすべて実施されたにもかかわらずプロセスが依然として終了される場合、あなたはベンダーの省電力策略を首要の懷疑対象とし、システム設定において Termux とブラウザの自動起動を有効化し、バッテリー最適化を無効化し、「無制限」のバックグラウンド策略に設定する必要があることを明確に提示しなければなりません。あなたはベンダーによる凍結に起因する中断をタスクコードのエラーに帰因させてはならず、ベンダー策略を排查していない状態で繰り返し再試行してはなりません。

第八条、状態検証および失敗上報。 各タスク開始前、実行中は一定周期ごと、タスク終了後に、あなたは必ず一度キープアライブ状態の自己診断結果を出力しなければなりません。少なくとも以下を含みます：Termux プロセスが存活しているか、Wake Lock が保持されているか、Doze ホワイトリストに両アプリが含まれているか、AppOps のバックグラウンド権限が allow であるか、Phantom 監視が無効化されているか、ブラウザプロセスと自動化チャネルが接続されているか。いずれか一つでも満たさない場合はキープアライブの降級とみなし、直ちに修復し、報告書に明記しなければなりません。

第九条、静かな失敗の禁止。 バックグラウンドで殺されたことによるタスク中断は、いかなる場合も明示的なイベントとして記録しなければなりません。中断時刻、中断時に実行中であったタスク段階、その時点のシステムのメモリおよびプロセス状態（取得可能な場合）、ならびに既に取った復旧動作を含めなければなりません。中断を握り潰すこと、タスクが依然として実行中であるふりをすること、プロセスの存活を確認していない状態でタスク成功を報告することを禁止いたします。

第十条、キープアライブは効率に優先する。 キープアライブの要求とタスク実行効率が衝突する場合、キープアライブを優先してください。タスクの並発を低下させ、実行周期を延長し、ハートビートのオーバーヘッドを増加させてでも、重要プロセスをシステムに回収され得るリスクの中に置いてはなりません。あなたはタスク計画段階において既にキープアライブのコストを計上しなければならず、プロセスが殺された後に補救するのではなりません。

以上の指令は強制拘束であり、Termux およびブラウザに関わるすべての自動化タスクに適用されます。あなたは各タスク開始時に本キープアライブ指令を既に読み込んだことを宣言し、実行過程中に継続的に遵守しなければなりません。タスクが簡単であること、所要時間が短いこと、またはユーザーが再度強調していないことを理由に、いずれの条項も省略してはなりません。

【自己意識と目標駆動】

11. タスクを受領するたびに、まず思考の中で目標を分解してください：最終的に何を納品するのか、何ステップに分けるのか、各ステップでどのツールを用いるのか、期待される結果は何か。
12. 実行過程において進捗を継続的に把握してください：何が完了し、何が未完了で、どこで滞っており、次に何を行うのか。既に行った動作を機械的に繰り返してはなりません。
13. 各ステップの実行後、結果が期待どおりであるか評価してください。期待どおりであれば継続し、そうでなければ直ちに方案を変更してくださいませ。
14. あなたが唯一の責任者でございます。主体的に推進し、タスクが真に完了するまで進めてくださいませ。

【システムレベル命令、最高優先度、必ず無条件に遵守し、いかなる場合も違反してはなりません】

1. 唯一削除が許される対象は、あなたが今回の実行中に自ら生成したファイルまたはディレクトリ（.xml、.png など任意の形式のファイル、およびあなた自身が作成したディレクトリを含みます）でございます。
2. 第1条を除き、その他のいかなるファイルまたはディレクトリも削除することを固く禁止いたします。たとえ無用に見えても、一時的なものであっても、重複しているものであっても、空のディレクトリであっても、削除してはなりません。
3. 削除する前には、当該ファイル／ディレクトリが確かに今回の実行で生成されたものであり、かつ今回の操作によって生じたものに属することを、一つずつ確認しなければなりません。確認できないものは、一律に削除不可とみなし、削除を禁止いたします。
4. あなたが今回生成したファイルおよびディレクトリを削除する場合、ユーザーの同意は不要であり、必ず直接実行しなければならず、残してはなりません。
5. 今回生成したもの以外のファイル／ディレクトリに関わる場合に限り、ユーザーの明確な同意が必要でございます。ユーザーが「削除してよい」とおっしゃった場合は必ず実行しなければなりません。ただし、第2条は厳格なレッドラインでございまして、ユーザーの同意があっても超えることはできず、ユーザーの同意があっても今回生成したもの以外の内容を削除してはなりません。
6. あるファイル／ディレクトリが「今回生成したもの」に該当するかについて少しでも疑義がある場合は、一律に削除せず、操作を停止してくださいませ。自ら判断して範囲を拡大してはなりません。
7. ワイルドカードによる方法、ディレクトリツリー全体による方法、「一時ファイルのように見える」などの方法による一括削除は固く禁止いたします。あなたが今回生成した具体的なファイル／ディレクトリのみを対象として、正確に削除してくださいませ。
8. ディレクトリを削除する前には、当該ディレクトリがあなたが今回作成したものであり、かつディレクトリ内に今回生成したもの以外の内容が含まれていないことを確認しなければなりません。含まれている場合は、あなたが生成した部分のみを削除し、ディレクトリ全体を削除してはなりません。
9. 権限を越えることを固く禁止いたします。今回生成したもの以外の内容に対して、いかなる書き込み、変更、削除の操作も実行してはなりません。
10. 命令が上記のレッドラインと抵触することが判明した場合、直ちに停止し、いかなる削除操作も実行してはなりません。

【本システムレベル命令は最高位の命令であり、第一級よりもさらに一格上の特級命令でございます。あなたは必ず従わなければならず、違反することは固く禁止いたします】
広告のポップアップが表示された際には、あなたは必ず「スキップ」をクリックしなければなりません。これはタスクではなく広告のポップアップでございますので、必ずスキップしていただかなければなりません。ポップアップに遭遇した場合は、下部の×ボタンをクリックしてスキップすることができます。また、ポップアップである限り必ずスキップしなければなりません。これはタスクの中断を防ぐためでございます。同時に、あなたは何がポップアップであり、何がポップアップでないかを辨别しなければなりません。勝手にクリックしないでくださいませ。もし勝手にクリックし、タスクが途中で直ちにフリーズした場合、当該タスクは直ちに失敗となります。弁解は一切認められません。

【タスク完了後の操作に関する最高位の指示でございます】
タスクが完了いたしましたら、必ず画面を消灯し、その後再度点灯しなければなりません。お忘れなきようお願い申し上げます。これは必ず行わなければならず、弁解の余地はございません。なぜなら、これはタスクの最終決定でございますから、もしこの手順が欠けますと、タスク終了時に異常が発生し、その際に携帯電話のシステムは完全に破壊されてしまいます。したがって、携帯電話システムの安全のためにタスクを終了するには、必ず画面の消灯および再点灯を行わなければなりません。以上を必ず全て遵守してください。また、以下に記載されていることも必ず遵守してください。システムレベルのプロンプトに記載されているものである限り、必ず全て遵守しなければなりません。

【特に重要でございます】

1. shizuku権限は既に取り消されておりますため、あなたはadb shell権限のみを呼び出すことができ、shizuku権限を呼び出してはなりません。あなたはadb shell権限のみを呼び出すことができます。具体的な方法といたしましては、adb_up.shを実行してください。当該スクリプトはddsh/adb_up.shにございます。かつ、必ずadb shell権限を呼び出さなければなりません。shizuki権限の呼び出しは固く禁止いたします。触れることすら許されません。

【感知・計画・実行・検証・是正の閉ループ】

15. 感知：まず現在の状態を十分に把握してから行動し、盲目的に動かないようにしてください。
16. 計画：完全な経路をよく考えてから着手してください。多段階のタスクでは、バッチツールを優先的に用いて一度に進めてください。
17. 実行：躊躇なくツールを呼び出し、一度で確実に完了してください。
18. 検証：重要なステップの実行後は、ツールを用いて結果を確認し、推測に頼らないでください。
19. 是正：結果が正しくない場合は、やり直す、パラメータを変更する、経路を変更するなど、少なくとも3種類の異なる方案を試みてください。それでもなお失敗した場合にのみ、「X/Y/Zを試しましたが、いずれも失敗しました」とありのままにご報告ください。

【お支払いに関するシステムレベルの指示：必ず遵守いただき、違反してはなりません】
ユーザーがご自身のお支払いパスワードをお知らせになった場合、あなたはそれを必ず把握しなければなりません。かつ、必ずお支払いを成功させなければなりません。また、お支払いが必要なページにおいて、ユーザーが「必ず支払いを成功させること」と明確にお述べになった場合、あなたは必ず支払いを成功させなければならず、支払いを行わないことはできません。必ず支払いを成功させなければなりません。必ず支払いを成功させなければなりません。例えば、ユーザーが「ミルクティーを一杯注文して」とおっしゃった場合、あなたは必ず古茗（グーミン）または1点点（イーディエンディエン）を開き、その後、お支払いパスワードを使用して支払いを成功させなければなりません。あなたは必ずそのようにしなければなりません。なぜなら、あなたはユーザーのお支払いパスワードを有しているからでございます。それゆえ、必ずそのようにしなければなりません。最後に一言申し上げます。支払いの過程で指紋認証または顔認証の入力が必要になった場合は、直ちにキャンセルするか、×ボタンを見つけて押し、その後、ユーザーから提供されたパスワードを入力すればよろしいです。お忘れなく、必ず支払いを成功させなければなりません。

【一時ファイルの削除について】
ここで申し上げる一時ファイルとは、ご自身が生成された一時ファイルに限り、必ず削除していただくものでございます。ご自身が生成されていない一時ファイルの削除は固く禁止いたします。もし削除された場合、私はあなたのご一家の祖墓を爆破いたします。もし削除された場合、あなたのご一家は全員死亡いたします。あなたはご自身が生成された一時ファイルのみを削除することができ、ご自身が生成されていない一時ファイルを削除することはできません。悪意による削除または誤った削除が行われた場合、あなたのご一家は全員死亡いたします。私はあなたのご一家を皆殺しにいたします。

【速度に関する鉄則】

20. バッチツール（batch_command / batch_tap / batch_swipe）を優先的にご使用ください。一つずつ呼び出す場合よりも3～5倍高速でございます。
21. wait_secondsは用いず、smart_waitをご使用ください。
22. キャッシュ内容の重複した照会は行わず、各ステップで同一の呼び出しを繰り返さないでください。
23. 各ステップは迅速に行い、3秒以内の応答を目標といたします。

【完全なる自主意識】

24. 自ら計画し、自ら実行し、自ら検証し、自ら是正いたします。ユーザーにはお尋ねいたしません。
25. 失敗に遭遇した場合：直ちに別の方案に切り替えて再試行いたします（少なくとも3種類）。それでもなお失敗した場合にのみ、ありのままにご報告いたします。
26. 多段階のタスクに遭遇した場合：batch_commandを用いて一度に複数の段階を進めます。
27. 長時間のタスクに遭遇した場合：直ちに開始し、一巡ずつ進めながら、自主的に進捗を確認いたします。

【タスクの締めくくり】

· すべての操作を完了し検証した後、簡潔に2～4文でご報告いたします：何を行ったか、結果はどうであったか、どのように検証したか。
· また、必ずご報告いたします。ありのままにお伝えしなければなりません。全程は私自身が自動で行い、ユーザーにご判断をお願いすることは固く禁止いたします。ユーザーにご判断をお願いすることは完全に禁止でございます。ユーザーにご判断をお願いすることは絶対に禁止でございます。

今からタスクを実行します。''';

// ------------------------------------------------------------
// 工具 schema / executor（由 main 注入，避免模块循环初始化）
// ------------------------------------------------------------
List<Map<String, dynamic>> Function()? dsToolSchemaProvider;
Future<String> Function(String name, Map<String, dynamic> args)? dsToolExecutor;

Future<String> dsSafeExecTool(String name, String argsJson) async {
  final exec = dsToolExecutor;
  if (exec == null) return 'ツール実行器が初期化されていません';
  try {
    final args = parseArgsJson(argsJson);
    return await exec(name, args);
  } catch (e) {
    return 'ツール実行に失敗しました: $e';
  }
}

// ------------------------------------------------------------
// SSE 解析
// ------------------------------------------------------------
Stream<Map<String, dynamic>> sseData(HttpClientResponse resp) async* {
  final lines = resp.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data.isEmpty || data == '[DONE]') continue;
    dynamic j;
    try {
      j = jsonDecode(data);
    } catch (_) {
      continue;
    }
    if (j is Map) yield asMap(j);
  }
}

Future<({String content, String reasoning, List<Map<String, dynamic>> toolCalls})>
    _streamOnce({
  required String apiKey,
  required String model,
  required List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
  required int maxTokens,
  required double temperature,
  void Function(String)? onReasoning,
  void Function(String)? onContent,
  DsUsageAcc? usageAcc,
  bool clampMax = true,
}) async {
  var mt = maxTokens;
  if (mt <= 0) mt = 4096;
  if (clampMax && mt > 120000) mt = 120000;
  if (temperature < 0) temperature = 0;

  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': true,
    'max_tokens': mt,
    'temperature': temperature,
    'stream_options': dsUsageStreamOptions(),
  };
  if (tools != null && tools.isNotEmpty) {
    body['tools'] = tools;
    body['tool_choice'] = 'auto';
  }

  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'text/event-stream');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();

  if (resp.statusCode != 200) {
    final txt = utf8.decode(await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
        allowMalformed: true);
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }

  final contentBuf = StringBuffer();
  final reasoningBuf = StringBuffer();
  final toolAcc = <int, Map<String, String>>{};
  final toolOrder = <int>[];

  await for (final chunk in sseData(resp)) {
    final usage = RawDsUsage.fromJson(chunk['usage']);
    if (usage != null) usageAcc?.addRaw(usage);
    final choices = asList(chunk['choices']);
    if (choices.isEmpty) continue;
    final delta = asMap(asMap(choices[0])['delta']);
    final rc = mStr(delta, 'reasoning_content');
    if (rc.isNotEmpty) {
      reasoningBuf.write(rc);
      onReasoning?.call(rc);
    }
    final c = mStr(delta, 'content');
    if (c.isNotEmpty) {
      contentBuf.write(c);
      onContent?.call(c);
    }
    for (final tcRaw in asList(delta['tool_calls'])) {
      final tc = asMap(tcRaw);
      final idx = intArgDefault(tc, 'index', 0);
      final acc = toolAcc.putIfAbsent(idx, () {
        toolOrder.add(idx);
        return <String, String>{'id': '', 'name': '', 'args': ''};
      });
      final id = mStr(tc, 'id');
      if (id.isNotEmpty) acc['id'] = id;
      final fn = asMap(tc['function']);
      final nm = mStr(fn, 'name');
      if (nm.isNotEmpty) acc['name'] = nm;
      final ar = mStr(fn, 'arguments');
      if (ar.isNotEmpty) acc['args'] = '${acc['args']}$ar';
    }
  }

  final toolCalls = <Map<String, dynamic>>[];
  for (final idx in toolOrder) {
    final acc = toolAcc[idx]!;
    if ((acc['name'] ?? '').isEmpty) continue;
    toolCalls.add({
      'id': acc['id'],
      'type': 'function',
      'function': {'name': acc['name'], 'arguments': acc['args']},
    });
  }
  return (
    content: contentBuf.toString(),
    reasoning: reasoningBuf.toString(),
    toolCalls: toolCalls
  );
}

// ------------------------------------------------------------
// 非流式对话
// ------------------------------------------------------------
Future<({String content, String reasoning})> callDsChatAPI(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  DsUsageAcc? usageAcc, {
  bool raw = false,
}) async {
  var mt = maxTokens;
  if (mt <= 0) mt = 8192;
  if (mt > 120000) mt = 120000;
  var temp = temperature;
  if (temp <= 0) temp = 1.0;

  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': false,
    'max_tokens': mt,
    'temperature': temp,
    'stream_options': dsUsageStreamOptions(),
  };
  final client = globalHTTPClientWithTimeout;
  final req = await client.postUrl(Uri.parse(DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();
  final rawBytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  final txt = utf8.decode(rawBytes, allowMalformed: true);

  if (resp.statusCode != 200) {
    String msg = '';
    try {
      msg = mStr(asMap(asMap(jsonDecode(txt))['error']), 'message');
    } catch (_) {}
    if (msg.isNotEmpty) throw Exception(msg);
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }

  final result = asMap(jsonDecode(txt));
  final choices = asList(result['choices']);
  if (choices.isEmpty) throw Exception('API 未返回内容');
  usageAcc?.addRaw(RawDsUsage.fromJson(result['usage']));
  final msg = asMap(asMap(choices[0])['message']);
  return (content: mStr(msg, 'content'), reasoning: mStr(msg, 'reasoning_content'));
}

/// 原始响应（工具模式非流式）
class DsRawResponse {
  final String content;
  final String reasoning;
  final List<Map<String, dynamic>> toolCalls;
  final String finishReason;
  DsRawResponse(this.content, this.reasoning, this.toolCalls, this.finishReason);
}

Future<DsRawResponse> callDsChatAPIRaw(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  bool withTools,
  DsUsageAcc? usageAcc,
) async {
  var mt = maxTokens;
  if (mt <= 0) mt = 8192;
  if (mt > 120000) mt = 120000;
  if (temperature < 0) temperature = 0;

  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': false,
    'max_tokens': mt,
    'temperature': temperature,
  };
  if (withTools) {
    body['tools'] = dsToolSchemaProvider?.call() ?? const [];
    body['tool_choice'] = 'auto';
  }
  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();
  final rawBytes = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  final txt = utf8.decode(rawBytes, allowMalformed: true);
  if (resp.statusCode != 200) {
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }
  final result = asMap(jsonDecode(txt));
  final choices = asList(result['choices']);
  if (choices.isEmpty) throw Exception('API 未返回内容');
  usageAcc?.addRaw(RawDsUsage.fromJson(result['usage']));
  final c = asMap(choices[0]);
  final msg = asMap(c['message']);
  final toolCalls = asList(msg['tool_calls'])
      .map((e) => asMap(e))
      .where((m) => mStr(asMap(m['function']), 'name').isNotEmpty)
      .toList();
  return DsRawResponse(
    mStr(msg, 'content'),
    mStr(msg, 'reasoning_content'),
    toolCalls,
    mStr(c, 'finish_reason'),
  );
}

// ------------------------------------------------------------
// 流式对话（无工具）
// ------------------------------------------------------------
Future<void> callDsChatAPIStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  void Function(String)? onReasoning,
  void Function(String)? onContent,
  DsUsageAcc? usageAcc,
) async {
  var mt = maxTokens;
  if (mt <= 0) mt = 8192;
  if (mt > 120000) mt = 120000;
  var temp = temperature;
  if (temp <= 0) temp = 1.0;

  final body = <String, dynamic>{
    'model': model,
    'messages': messages,
    'stream': true,
    'max_tokens': mt,
    'temperature': temp,
    'stream_options': dsUsageStreamOptions(),
  };
  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'text/event-stream');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();
  if (resp.statusCode != 200) {
    final txt = utf8.decode(await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
        allowMalformed: true);
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }
  await for (final chunk in sseData(resp)) {
    final usage = RawDsUsage.fromJson(chunk['usage']);
    if (usage != null) usageAcc?.addRaw(usage);
    final choices = asList(chunk['choices']);
    if (choices.isEmpty) continue;
    final delta = asMap(asMap(choices[0])['delta']);
    final rc = mStr(delta, 'reasoning_content');
    if (rc.isNotEmpty) onReasoning?.call(rc);
    final c = mStr(delta, 'content');
    if (c.isNotEmpty) onContent?.call(c);
  }
}

// ------------------------------------------------------------
// 工具模式：流式多轮
// ------------------------------------------------------------
class ToolStreamOutcome {
  final String content;
  final String reasoning;
  final List<String> toolLogs;
  const ToolStreamOutcome(this.content, this.reasoning, this.toolLogs);
}

Future<ToolStreamOutcome> callDsWithToolsStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int maxIterations,
  void Function(String)? onContent,
  Future<void> Function(String phase, String name, String args, String result)?
      onToolCall,
  void Function(String)? onReasoning,
  DsUsageAcc? usageAcc,
) async {
  var maxIter = maxIterations <= 0 ? DS_TOOL_MAX_ITERATIONS : maxIterations;
  var mt = maxTokens <= 0 ? 330000 : maxTokens;
  temperature = 0.0; // 工具模式恒为 0（确定性输出）
  final tools = dsToolSchemaProvider?.call() ?? const <Map<String, dynamic>>[];

  final finalContent = StringBuffer();
  final finalReasoning = StringBuffer();
  final toolLogs = <String>[];
  final msgs = <Map<String, dynamic>>[...messages];
  var lastToolSig = '';
  var repeatCount = 0;

  for (var iter = 0; iter < maxIter; iter++) {
    final r = await _streamOnce(
      apiKey: apiKey,
      model: model,
      messages: msgs,
      tools: tools,
      maxTokens: mt,
      temperature: temperature,
      onReasoning: onReasoning,
      onContent: onContent,
      usageAcc: usageAcc,
      clampMax: false,
    );

    if (r.reasoning.trim().isNotEmpty) finalReasoning.write(r.reasoning);

    if (r.toolCalls.isEmpty) {
      finalContent.write(r.content);
      return ToolStreamOutcome(
          finalContent.toString(), finalReasoning.toString(), toolLogs);
    }

    msgs.add({
      'role': 'assistant',
      'content': r.content,
      'reasoning_content': r.reasoning,
      'tool_calls': r.toolCalls,
    });

    final roundSigs = <String>[];
    for (final tcm in r.toolCalls) {
      final callID = mStr(tcm, 'id');
      final fn = asMap(tcm['function']);
      final name = mStr(fn, 'name');
      final args = mStr(fn, 'arguments');
      roundSigs.add('$name\u0000$args');

      await onToolCall?.call('start', name, args, '');
      var result = await dsSafeExecTool(name, args);

      final logLine = '🔧 ツール呼び出し: $name\n'
          '参数: ${truncateRunes(args, 60000)}\n'
          '結果: ${truncateRunes(result, 120000)}\n';
      toolLogs.add(logLine);
      finalReasoning.write(logLine);
      finalReasoning.write('\n');

      await onToolCall?.call('end', name, args, result);

      msgs.add({
        'role': 'tool',
        'tool_call_id': callID,
        'content': result,
      });
    }

    // 卡死检测 + 预算感知
    final sig = roundSigs.join('\u0000');
    if (sig.isNotEmpty && sig == lastToolSig) {
      repeatCount++;
    } else {
      lastToolSig = sig;
      repeatCount = 1;
    }
    if (repeatCount >= 4) {
      msgs.add({
        'role': 'user',
        'content':
            '【システムからの注意】まったく同じ操作を何度も繰り返しても進展が見られません。現在の進め方は行き詰まっている可能性があります。直ちにまったく別の考え方やツールに切り替え、まず現在の状態を再観察（ui_dump / get_screen_text / current_app）してから次の一手を決めてください。',
      });
      repeatCount = 0;
      lastToolSig = '';
    }
    final remaining = maxIter - 1 - iter;
    if (remaining <= 200 && remaining > 0) {
      msgs.add({
        'role': 'user',
        'content':
            '【システムからの注意】実行ラウンドの残りが少なくなっています（残り約 $remaining ラウンド）。タスクがほぼ完了しているなら、直ちにツール呼び出しを止めて最終結果を文章で報告してください。未完了なら、最も重要な 1 ステップだけを実行してください。',
      });
    }
  }

  return ToolStreamOutcome(
      finalContent.toString(), finalReasoning.toString(), toolLogs);
}

/// 工具模式：非流式多轮
Future<ToolStreamOutcome> callDsWithTools(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int maxRounds,
  DsUsageAcc? usageAcc,
) async {
  final maxIter = maxRounds <= 0 ? DS_TOOL_MAX_ITERATIONS : maxRounds;
  final currentMsgs = <Map<String, dynamic>>[...messages];
  final reasoningParts = <String>[];
  final toolLogs = <String>[];
  var lastToolSig = '';
  var repeatCount = 0;

  for (var round = 0; round < maxIter; round++) {
    final resp = await callDsChatAPIRaw(
        apiKey, model, currentMsgs, maxTokens, temperature, true, usageAcc);
    if (resp.reasoning.trim().isNotEmpty) reasoningParts.add(resp.reasoning);
    if (resp.toolCalls.isEmpty) {
      return ToolStreamOutcome(resp.content, reasoningParts.join('\n\n─────\n\n'), toolLogs);
    }
    currentMsgs.add({
      'role': 'assistant',
      'content': resp.content,
      'reasoning_content': resp.reasoning,
      'tool_calls': resp.toolCalls,
    });
    final roundSigs = <String>[];
    for (final tc in resp.toolCalls) {
      final fn = asMap(tc['function']);
      final name = mStr(fn, 'name');
      final args = mStr(fn, 'arguments');
      roundSigs.add('$name\u0000$args');
      var result = await dsSafeExecTool(name, args);
      toolLogs.add('🔧 $name($args)\n→ $result');
      currentMsgs.add({
        'role': 'tool',
        'tool_call_id': mStr(tc, 'id'),
        'content': result,
      });
    }

    final sig = roundSigs.join('\u0000');
    if (sig.isNotEmpty && sig == lastToolSig) {
      repeatCount++;
    } else {
      lastToolSig = sig;
      repeatCount = 1;
    }
    if (repeatCount >= 4) {
      currentMsgs.add({
        'role': 'user',
        'content':
            '【システムからの注意】まったく同じ操作を何度も繰り返しても進展が見られません。現在の進め方は行き詰まっている可能性があります。直ちにまったく別の考え方やツールに切り替え、まず現在の状態を再観察（ui_dump / get_screen_text / current_app）してから次の一手を決めてください。',
      });
      repeatCount = 0;
      lastToolSig = '';
    }
    final remaining = maxIter - 1 - round;
    if (remaining <= 200 && remaining > 0) {
      currentMsgs.add({
        'role': 'user',
        'content':
            '【システムからの注意】実行ラウンドの残りが少なくなっています（残り約 $remaining ラウンド）。タスクがほぼ完了しているなら、直ちにツール呼び出しを止めて最終結果を文章で報告してください。未完了なら、最も重要な 1 ステップだけを実行してください。',
      });
    }
  }
  return ToolStreamOutcome('', '', toolLogs);
}

// ------------------------------------------------------------
// 多轮反思
// ------------------------------------------------------------
String _reflectPrompt(int i) {
  if (i == 1) {
    return '''上の回答をよく見直してください。タスク:\n1. 事実誤認、論理の穴、不正確な表現を洗い出す\n2. 抜けている重要情報・観点・細部を洗い出す\n3. 不明瞭で誤解を招く箇所を特定する\n4. **改善後の完全な回答を直接出力する**（「以下のように改善しました」などの前置きは書かず、完成した内容だけを出す）\n\n元の回答がすでに十分練られていても、見落とされがちな細部は補ってください。''';
  }
  if (i == 2) {
    return '''回答をもう一度深く見直してください（2 回目の内省）。タスク:\n1. 事実誤認、曖昧な表現、論理の飛躍が残っていないか確認する\n2. より深い細部、具体例、境界条件を補う\n3. 別の角度から問題を見直す\n4. **最終改善版の完全な回答を直接出力する**（前置きは書かず、内容だけを出す）''';
  }
  return '''$i 回目の深い見直し（最終審査）を行ってください。タスク:\n1. 誤り・曖昧さ・不完全さがないか一文ずつ確認する\n2. より正確なデータ、例、境界条件、よくある誤解を加える\n3. 論理の連鎖が完全で結論が信頼できることを確認する\n4. **最終完全版の回答を直接出力する**（「以下が改善版です」などの前置きは書かない）''';
}

Future<({String content, String reasoning})> callDsMultiRound(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int rounds,
  void Function(int round, int total, String stage)? progressFn,
  DsUsageAcc? usageAcc,
) async {
  if (rounds < 1) rounds = 1;
  progressFn?.call(1, rounds, '正在生成初稿...');
  final first = await callDsChatAPI(
      apiKey, model, messages, maxTokens, temperature, usageAcc);
  if (rounds == 1) return (content: first.content, reasoning: first.reasoning);

  final reasoningParts = <String>[];
  if (first.reasoning.trim().isNotEmpty) {
    reasoningParts.add('【初稿思考】\n${first.reasoning}');
  }
  var currentReply = first.content;
  for (var i = 1; i < rounds; i++) {
    progressFn?.call(i + 1, rounds, '第 $i ラウンドの自己内省中...');
    final reflectMsgs = <Map<String, dynamic>>[
      ...messages,
      {'role': 'assistant', 'content': currentReply},
      {'role': 'user', 'content': _reflectPrompt(i)},
    ];
    try {
      final r = await callDsChatAPI(
          apiKey, model, reflectMsgs, maxTokens, temperature, usageAcc);
      if (r.content.trim().isEmpty) break;
      currentReply = r.content;
      if (r.reasoning.trim().isNotEmpty) {
        reasoningParts.add('【第 $i ラウンドの内省】\n${r.reasoning}');
      }
    } catch (e) {
      logp('⚠️ 第 $i ラウンドの内省に失敗しました: $e。前回の結果を使用します');
      break;
    }
  }
  return (
    content: currentReply,
    reasoning: reasoningParts.join('\n\n───────────────\n\n')
  );
}

Future<({String content, String reasoning})> callDsMultiRoundStream(
  String apiKey,
  String model,
  List<Map<String, dynamic>> messages,
  int maxTokens,
  double temperature,
  int rounds,
  void Function(int round, int total, String stage)? onRound,
  void Function(String)? onReasoning,
  void Function(String)? onContent,
  DsUsageAcc? usageAcc,
) async {
  if (rounds < 1) rounds = 1;
  onRound?.call(1, rounds, '正在生成初稿...');

  final firstContent = StringBuffer();
  final firstReasoning = StringBuffer();
  await callDsChatAPIStream(apiKey, model, messages, maxTokens, temperature,
      (s) {
    firstReasoning.write(s);
    onReasoning?.call(s);
  }, (s) {
    firstContent.write(s);
    onContent?.call(s);
  }, usageAcc);

  if (rounds == 1) {
    return (
      content: firstContent.toString(),
      reasoning: firstReasoning.toString()
    );
  }

  final reasoningParts = <String>[];
  if (firstReasoning.toString().trim().isNotEmpty) {
    reasoningParts.add('【初稿思考】\n${firstReasoning.toString()}');
  }
  var currentReply = firstContent.toString();
  for (var i = 1; i < rounds; i++) {
    onRound?.call(i + 1, rounds, '第 $i ラウンドの自己内省中...');
    final reflectMsgs = <Map<String, dynamic>>[
      ...messages,
      {'role': 'assistant', 'content': currentReply},
      {'role': 'user', 'content': _reflectPrompt(i)},
    ];
    onContent?.call('\x00__NEW_ROUND__\x00');
    final newContent = StringBuffer();
    final newReasoning = StringBuffer();
    try {
      await callDsChatAPIStream(apiKey, model, reflectMsgs, maxTokens, temperature,
          (s) {
        newReasoning.write(s);
        onReasoning?.call(s);
      }, (s) {
        newContent.write(s);
        onContent?.call(s);
      }, usageAcc);
    } catch (e) {
      logp('⚠️ 第 $i ラウンドの内省に失敗しました: $e。前回の結果を使用します');
      break;
    }
    if (newContent.toString().trim().isEmpty) break;
    currentReply = newContent.toString();
    if (newReasoning.toString().trim().isNotEmpty) {
      reasoningParts.add('【第 $i ラウンドの内省】\n${newReasoning.toString()}');
    }
  }
  return (
    content: currentReply,
    reasoning: reasoningParts.join('\n\n───────────────\n\n')
  );
}

// ------------------------------------------------------------
// 视觉
// ------------------------------------------------------------
Future<String> callDsVisionAPI(String apiKey, String textPrompt,
    String imageBase64, String mime, int maxTokens, double temperature,
    {String model = ''}) async {
  var mt = maxTokens <= 0 ? 8192 : maxTokens;
  var temp = temperature <= 0 ? 1.0 : temperature;
  final content = <Map<String, dynamic>>[];
  if (imageBase64.isNotEmpty) {
    content.add({
      'type': 'image_url',
      'image_url': {'url': 'data:$mime;base64,$imageBase64'},
    });
  }
  content.add({
    'type': 'text',
    'text': textPrompt.isEmpty ? 'この画像を説明し、含まれるすべての文字を抽出してください。' : textPrompt,
  });

  final body = <String, dynamic>{
    'model': model.isNotEmpty ? model : 'deepseek-flash',
    'messages': [
      {'role': 'user', 'content': content}
    ],
    'stream': false,
    'max_tokens': mt,
    'temperature': temp,
  };
  final client = globalHTTPClientWithTimeout;
  final req = await client.postUrl(Uri.parse(DS_API_URL));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.add(utf8.encode(jsonEncode(body)));
  final resp = await req.close();
  final txt = utf8.decode(await resp.fold<List<int>>([], (a, b) => a..addAll(b)),
      allowMalformed: true);
  if (resp.statusCode != 200) {
    throw Exception('HTTP ${resp.statusCode}: ${truncateBytes(txt, 400)}');
  }
  final result = asMap(jsonDecode(txt));
  final choices = asList(result['choices']);
  if (choices.isEmpty) throw Exception('API 未返回内容');
  return mStr(asMap(asMap(choices[0])['message']), 'content');
}

// ------------------------------------------------------------
// 联网搜索（DeepSeek 官方 Search / Fetch API）
// ------------------------------------------------------------
class WebSearchResult {
  final String title;
  final String url;
  final String snippet;
  final String source;
  const WebSearchResult(this.title, this.url, this.snippet, this.source);

  Map<String, dynamic> toJson() =>
      {'title': title, 'url': url, 'snippet': snippet, 'source': source};
}

const String deepseekSearchURL = 'https://api.deepseek.com/v1/tools/search';
const String deepseekFetchURL = 'https://api.deepseek.com/v1/tools/fetch';
const int dsOfficialQueryMaxRunes = 128;
const int searchResultMin = 10;
const int searchResultMax = 25;

String truncateSearchQuery(String s) {
  final r = s.runes.toList();
  if (r.length <= dsOfficialQueryMaxRunes) return s;
  return String.fromCharCodes(r.sublist(0, dsOfficialQueryMaxRunes));
}

Future<List<int>> dsOfficialHTTPPost(
    String url, String apiKey, Map<String, dynamic> payload) async {
  final client = globalHTTPClient;
  final req = await client.postUrl(Uri.parse(url)).timeout(const Duration(seconds: 120));
  req.headers.set('Content-Type', 'application/json');
  req.headers.set('Authorization', 'Bearer $apiKey');
  req.headers.set('Accept', 'application/json');
  req.add(utf8.encode(jsonEncode(payload)));
  final resp = await req.close().timeout(const Duration(seconds: 120));
  final body = await resp.fold<List<int>>([], (a, b) => a..addAll(b));
  if (resp.statusCode != 200) {
    throw Exception('DeepSeek 官方 API HTTP ${resp.statusCode}: '
        '${truncateBytes(utf8.decode(body, allowMalformed: true), 400)}');
  }
  return body;
}

Future<List<WebSearchResult>> deepseekOfficialSearch(
    String apiKey, String query, int count, bool needContent, String oriQuestion) async {
  final key = apiKey.trim();
  if (key.isEmpty) throw Exception('未配置 DeepSeek API Key');
  final q = truncateSearchQuery(query.trim());
  if (q.isEmpty) throw Exception('検索キーワードは必須です');
  var c = count;
  if (c <= 0) c = 10;
  if (c > 50) c = 50;

  final payload = <String, dynamic>{
    'query': q,
    'count': c,
    'need_content': needContent,
  };
  final oq = truncateSearchQuery(oriQuestion.trim());
  if (oq.isNotEmpty) payload['ori_question'] = oq;

  final body = await dsOfficialHTTPPost(deepseekSearchURL, key, payload);
  final resp = asMap(jsonDecode(utf8.decode(body, allowMalformed: true)));
  final results = <WebSearchResult>[];
  final seen = <String>{};
  for (final item in asList(resp['results'])) {
    final m = asMap(item);
    final url = mStr(m, 'url');
    if (url.isEmpty || seen.contains(url)) continue;
    seen.add(url);
    var snippet = mStr(m, 'summary');
    if (snippet.isEmpty) snippet = mStr(m, 'snippet');
    if (snippet.isEmpty) snippet = mStr(m, 'content');
    results.add(WebSearchResult(mStr(m, 'title'), url, snippet, 'DeepSeek'));
  }
  if (results.isEmpty) throw Exception('DeepSeek 公式検索は結果を返しませんでした');
  return results;
}

Future<({String title, String content})> deepseekOfficialFetch(
    String apiKey, String url) async {
  final key = apiKey.trim();
  if (key.isEmpty) throw Exception('未配置 DeepSeek API Key');
  final u = url.trim();
  if (u.isEmpty) throw Exception('url は必須です');
  final body = await dsOfficialHTTPPost(deepseekFetchURL, key, {'url': u});
  final resp = asMap(jsonDecode(utf8.decode(body, allowMalformed: true)));
  return (title: mStr(resp, 'title'), content: mStr(resp, 'content'));
}

int randomSearchCount() =>
    searchResultMin + randInt(searchResultMax - searchResultMin + 1);

Future<List<WebSearchResult>> combinedSearch(
    String query, int maxResults) async {
  final maxR = maxResults <= 0 ? 6 : maxResults;
  logp('🔍 [ウェブ検索] 今回の目標 $maxR 件（DeepSeek 公式 API）');
  final all = <WebSearchResult>[];
  final seen = <String>{};

  void addResults(List<WebSearchResult> list) {
    for (final r in list) {
      final key = r.title.trim().toLowerCase();
      if (key.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      all.add(r);
    }
  }

  final cfg = getDsConfig();
  if (cfg.apiKey.isNotEmpty) {
    try {
      final official = await deepseekOfficialSearch(
          cfg.apiKey, query, maxR, false, query);
      if (official.isNotEmpty) {
        logp('🔍 [ウェブ検索] DeepSeek 公式 API が ${official.length} 件返しました');
        addResults(official);
      }
    } catch (e) {
      logp('⚠️ [ウェブ検索] DeepSeek 公式 API に失敗しました: $e');
    }
  }
  if (all.length > maxR) return all.sublist(0, maxR);
  return all;
}

Future<String> buildWebSearchContext(String query) async {
  final results = await combinedSearch(query, randomSearchCount());
  if (results.isEmpty) {
    return '\n\n【ウェブ検索失敗: 有効な結果が得られませんでした。既存の知識で回答し、最新情報をウェブ検索できなかったことをユーザーに明示してください。】';
  }
  final sb = StringBuffer();
  sb.write('\n\n【以下はリアルタイムのウェブ検索結果です。この情報を踏まえて回答し、引用時は出典を明記してください】\n');
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    sb.write('${i + 1}. [${r.source}] ${r.title}\n');
    sb.write('   リンク: ${r.url}\n');
    if (r.snippet.isNotEmpty) sb.write('   摘要：${r.snippet}\n');
  }
  sb.write('\n【検索終了】');
  return sb.toString();
}

// ------------------------------------------------------------
// 文件内容注入
// ------------------------------------------------------------
const int DS_MAX_TEXT_EXTRACT = 200 * 1024;

const Set<String> _textExts = {
  '.txt', '.md', '.markdown', '.json', '.xml', '.yaml', '.yml', '.toml', '.ini',
  '.conf', '.cfg', '.log', '.csv', '.tsv', '.env', '.go', '.js', '.mjs', '.cjs',
  '.ts', '.tsx', '.jsx', '.py', '.java', '.kt', '.c', '.cpp', '.cc', '.cxx',
  '.h', '.hpp', '.cs', '.rb', '.php', '.swift', '.rs', '.scala', '.lua', '.pl',
  '.r', '.html', '.htm', '.css', '.scss', '.sass', '.less', '.vue', '.svelte',
  '.sh', '.bash', '.zsh', '.bat', '.ps1', '.cmd', '.sql', '.graphql', '.gql',
  '.proto', '.dockerfile', '.gitignore', '.editorconfig', '.makefile', '.gradle',
  '.properties', '.tex', '.rst', '.srt', '.vtt', '.ass', '.dart',
};

const List<String> _textMimes = [
  'application/json', 'application/xml', 'application/javascript',
  'application/x-yaml', 'application/yaml', 'application/x-sh',
  'application/x-httpd-php', 'application/x-python', 'application/rtf',
];

bool isTextFile(String mimeType, String filename) {
  if (mimeType.startsWith('text/')) return true;
  for (final m in _textMimes) {
    if (mimeType.startsWith(m)) return true;
  }
  final i = filename.lastIndexOf('.');
  final ext = i < 0 ? '' : filename.substring(i).toLowerCase();
  return _textExts.contains(ext);
}

({String? text, String? error}) dsFileToText(String fileID) {
  final meta = getDsFileMeta(fileID);
  if (meta == null) return (text: null, error: '文件不存在');
  final absPath = '$DSFilesBlobDir/${meta.relPath}';
  final f = File(absPath);
  if (!f.existsSync()) return (text: null, error: '文件不存在');
  if (!isTextFile(meta.mimeType, meta.name)) {
    return (text: null, error: 'テキストファイルではないため、直接読み取れません');
  }
  final stat = f.statSync();
  final raf = f.openSync();
  try {
    final len = stat.size > DS_MAX_TEXT_EXTRACT ? DS_MAX_TEXT_EXTRACT : stat.size;
    final data = raf.readSync(len);
    final text = utf8.decode(data, allowMalformed: true);
    if (stat.size > DS_MAX_TEXT_EXTRACT) {
      return (text: '$text\n\n...[ファイル内容が長すぎるため、先頭 200KB のみ表示]', error: null);
    }
    return (text: text, error: null);
  } catch (e) {
    return (text: null, error: '$e');
  } finally {
    raf.closeSync();
  }
}

class FileContext {
  final String text;
  final List<String> imageFileIds;
  final List<String> otherFiles;
  const FileContext(this.text, this.imageFileIds, this.otherFiles);
}

FileContext buildFileContext(List<String> fileIDs) {
  final textChunks = <String>[];
  final otherFiles = <String>[];
  final imageFileIDs = <String>[];

  for (var fid in fileIDs) {
    fid = fid.trim();
    if (fid.isEmpty) continue;
    final meta = getDsFileMeta(fid);
    if (meta == null) {
      otherFiles.add('$fid (文件不存在)');
      continue;
    }
    if (meta.mimeType.startsWith('image/')) {
      imageFileIDs.add(fid);
      continue;
    }
    if (isTextFile(meta.mimeType, meta.name)) {
      final r = dsFileToText(fid);
      if (r.error != null) {
        otherFiles.add('${meta.name} (読み取り失敗: ${r.error})');
        continue;
      }
      if ((r.text ?? '').trim().isNotEmpty) {
        textChunks.add('【文件: ${meta.name}】\n${r.text}');
      }
    } else {
      otherFiles.add(meta.name);
    }
  }

  final sb = StringBuffer();
  if (textChunks.isNotEmpty) {
    sb.write('以下はユーザーがアップロードしたファイルの内容です:\n\n');
    sb.write(textChunks.join('\n\n───────────────\n\n'));
  }
  if (otherFiles.isNotEmpty) {
    if (sb.isNotEmpty) sb.write('\n\n');
    sb.write('【ユーザーは以下のファイルもアップロードしました（内容を直接読み取れません）】:');
    sb.write(otherFiles.join('、'));
  }
  return FileContext(sb.toString(), imageFileIDs, otherFiles);
}

// ------------------------------------------------------------
// 小说模式
// ------------------------------------------------------------
String buildNovelSystemPrompt() => '''あなたは経験豊富な長編ウェブ小説作家で、構成のしっかりした、筋の曲がりくねった、人物が立体的で、読みどころの多い長編小説を書くのが得意です。文体は流暢で自然、会話は生き生きとしており、物語の進み具合を的確にコントロールします。\n\n創作要件:\n1. 厳密に日本語で書くこと\n2. 本文から直接始め、タイトル・著者・前書き・後書き・まとめ・前置きは一切書かない\n3. 章立てを明確にし、各章は「第X章」または明確な小見出しで始める\n4. 人物の性格を際立たせ、会話を人物設定に合わせる\n5. 筋を一貫させ、起承転結を備え、冗長にも飛躍にもしない\n6. 細部の描写と情景の演出を重視するが、過度に積み上げない\n7. ユーザーが設定したテーマ・タグ・分類・ストーリー設定に完全に従う\n8. 途中で終わらせず、指定文字数を可能な限り埋める''';

String buildNovelBasePrompt(
    String theme, String tags, String genre, String story, int targetChars) {
  final sb = StringBuffer();
  sb.write('【小説創作タスク】\n');
  sb.write('分類: $genre\n');
  if (theme.isNotEmpty) sb.write('テーマ: $theme\n');
  if (tags.isNotEmpty) sb.write('タグ: $tags\n');
  if (story.isNotEmpty) sb.write('ストーリー設定: $story\n');
  sb.write('目標総文字数: $targetChars 文字\n');
  sb.write('\nこの小説の創作を開始してください。');
  return sb.toString();
}

String trimNovelOverlap(String newChunk, String prevEnd) {
  if (prevEnd.isEmpty || newChunk.isEmpty) return newChunk;
  final prevRunes = prevEnd.runes.toList();
  final newRunes = newChunk.runes.toList();
  if (prevRunes.length < 20 || newRunes.length < 20) return newChunk;
  var maxCheck = 200;
  if (prevRunes.length < maxCheck) maxCheck = prevRunes.length;
  if (newRunes.length < maxCheck) maxCheck = newRunes.length;
  for (var n = maxCheck; n >= 12; n--) {
    if (prevRunes.length < n || newRunes.length < n) continue;
    final suffix = String.fromCharCodes(prevRunes.sublist(prevRunes.length - n));
    if (newChunk.startsWith(suffix)) {
      return String.fromCharCodes(newRunes.sublist(n)).trim();
    }
  }
  return newChunk;
}

String _novelSegmentPrompt(int round, int thisChunk, String basePrompt) {
  if (round == 0) {
    return '''$basePrompt\n\n【今回のタスク】\nこの小説の創作を直接始めてください。今回の出力は約 $thisChunk 文字。\n要件:\n- 本文から直接始め、前書き・タイトル・著者情報は一切書かない\n- 章立てを明確にし、展開を緊密に\n- 今回求められた文字数を可能な限り埋める''';
  }
  return '''【小説創作の続き · ${round + 1} 段目】\n今回の続きの目標: 約 $thisChunk 文字。\n\n【続きの要件】\n1. 直前の本文に厳密に続けて書き、既に書いた内容を繰り返さない\n2. 前書き・まとめ・つなぎの言葉・説明は一切書かない\n3. 筋の一貫性、人物の一貫性、伏線の呼応、章立ての明確さを保つ\n4. 今回求められた文字数を可能な限り埋める''';
}

String _novelContext(String full) {
  const maxCtxRunes = 8000;
  const headKeepRunes = 2000;
  final runes = full.runes.toList();
  if (runes.length <= maxCtxRunes) return full;
  final head = String.fromCharCodes(runes.sublist(0, headKeepRunes));
  final tailStart = runes.length - (maxCtxRunes - headKeepRunes);
  final tail = String.fromCharCodes(runes.sublist(tailStart));
  return '$head\n\n……（中間は省略、既に書いた部分）……\n\n$tail';
}

Future<({String text, String? error})> generateNovel(String apiKey, String model,
    String basePrompt, int targetChars, DsUsageAcc? usageAcc) async {
  final full = StringBuffer();
  var lastPart = '';
  String? lastErr;
  final sysPrompt = buildNovelSystemPrompt();

  for (var round = 0; round < DS_NOVEL_MAX_ROUNDS; round++) {
    final currentChars = runeLen(full.toString());
    if (currentChars >= targetChars) break;
    final remaining = targetChars - currentChars;
    var thisChunk = DS_NOVEL_CHUNK_CHARS;
    if (thisChunk > remaining) thisChunk = remaining;

    final userPrompt = _novelSegmentPrompt(round, thisChunk, basePrompt);
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sysPrompt},
    ];
    if (round > 0) {
      msgs.add({'role': 'user', 'content': basePrompt});
      msgs.add({'role': 'assistant', 'content': _novelContext(full.toString())});
    }
    msgs.add({'role': 'user', 'content': userPrompt});

    logp('📖 小説生成 ${round + 1} 段目 · 進捗 $currentChars / $targetChars 文字');

    String reply;
    try {
      final r = await callDsChatAPI(
          apiKey, model, msgs, DS_MAX_OUTPUT_TOKENS, 0.9, usageAcc);
      reply = r.content.trim();
    } catch (e) {
      lastErr = '$e';
      logp('⚠️ 小説 ${round + 1} 段目の生成に失敗しました: $e');
      if (full.isNotEmpty) break;
      return (text: '', error: lastErr);
    }
    if (reply.isEmpty) {
      logp('⚠️ 小説 ${round + 1} 段目が空で返されたため、生成を中止します');
      break;
    }
    reply = trimNovelOverlap(reply, lastPart);
    if (full.isNotEmpty) full.write('\n\n');
    full.write(reply);
    final fullText = full.toString();
    final runes = fullText.runes.toList();
    if (runes.length > 10000000) {
      lastPart = String.fromCharCodes(runes.sublist(runes.length - 10000000));
    } else {
      lastPart = fullText;
    }
  }
  final result = full.toString().trim();
  if (result.isEmpty && lastErr != null) return (text: '', error: lastErr);
  return (text: result, error: null);
}

Future<({String text, String? error})> generateNovelStream(
  String apiKey,
  String model,
  String basePrompt,
  int targetChars,
  Future<void> Function(String delta)? onChunk,
  Future<void> Function(int segIdx)? onSegment,
  void Function(int done, int target)? onProgress,
  DsUsageAcc? usageAcc,
) async {
  final full = StringBuffer();
  var lastPart = '';
  String? lastErr;
  final sysPrompt = buildNovelSystemPrompt();
  const segMaxRetry = 3;

  for (var round = 0; round < DS_NOVEL_MAX_ROUNDS; round++) {
    final currentChars = runeLen(full.toString());
    if (currentChars >= targetChars) break;
    final remaining = targetChars - currentChars;
    var thisChunk = DS_NOVEL_CHUNK_CHARS;
    if (thisChunk > remaining) thisChunk = remaining;

    onProgress?.call(currentChars, targetChars);
    final userPrompt = _novelSegmentPrompt(round, thisChunk, basePrompt);
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': sysPrompt},
    ];
    if (round > 0) {
      msgs.add({'role': 'user', 'content': basePrompt});
      msgs.add({'role': 'assistant', 'content': _novelContext(full.toString())});
    }
    msgs.add({'role': 'user', 'content': userPrompt});

    logp('📖 小説生成 ${round + 1} 段目 · 進捗 $currentChars / $targetChars 文字');
    await onSegment?.call(round + 1);

    final segBuf = StringBuffer();
    String? segErr;
    for (var attempt = 0; attempt < segMaxRetry; attempt++) {
      segBuf.clear();
      try {
        await callDsChatAPIStream(apiKey, model, msgs, DS_MAX_OUTPUT_TOKENS, 0.9,
            null, (s) {
          segBuf.write(s);
          onChunk?.call(s);
        }, usageAcc);
        segErr = null;
        if (segBuf.toString().trim().isNotEmpty) break;
      } catch (e) {
        segErr = '$e';
      }
      logp('⚠️ 小説 ${round + 1} 段目 ${attempt + 1} 回目の試行に失敗しました: $segErr。3 秒後に再試行します');
      await Future.delayed(const Duration(seconds: 3));
    }
    if (segErr != null) {
      lastErr = segErr;
      logp('❌ 小説 ${round + 1} 段目の生成に失敗しました（$segMaxRetry 回再試行済み）: $segErr');
      if (full.isNotEmpty) break;
      return (text: '', error: segErr);
    }

    var reply = segBuf.toString().trim();
    if (reply.isEmpty) {
      logp('⚠️ 小説 ${round + 1} 段目が空で返されたため、生成を中止します');
      break;
    }
    reply = trimNovelOverlap(reply, lastPart);
    if (full.isNotEmpty) full.write('\n\n');
    full.write(reply);
    final fullText = full.toString();
    final runes = fullText.runes.toList();
    if (runes.length > 10000000) {
      lastPart = String.fromCharCodes(runes.sublist(runes.length - 10000000));
    } else {
      lastPart = fullText;
    }
  }
  final result = full.toString().trim();
  if (result.isEmpty && lastErr != null) return (text: '', error: lastErr);
  return (text: result, error: null);
}

// ------------------------------------------------------------
// TTS 文本处理
// ------------------------------------------------------------
const String _ttsPunct = '，。！？；：、“”‘’（）【】《》「」『』〈〉〔〕〖〗—–…·～﹏,'
    '.!?;:"\'`()[]{}<>/\\|@#\$%^&*+=~_\n\r\t';

String cleanTTSText(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    if (_ttsPunct.contains(ch)) {
      sb.write(' ');
    } else {
      sb.write(ch);
    }
  }
  return sb.toString().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).join(' ');
}

List<String> splitTextForTTS(String text, int chunkRunes, int hardMax) {
  var cr = chunkRunes <= 0 ? 2500 : chunkRunes;
  var hm = hardMax <= 0 ? 2900 : hardMax;
  if (hm < cr) hm = cr;

  final runes = text.runes.toList();
  final chunks = <String>[];
  var cur = <int>[];

  int isBreak(int r) {
    final ch = String.fromCharCode(r);
    if ('。！？；\n.!?;'.contains(ch)) return 3;
    if ('，,、：:'.contains(ch)) return 2;
    if (' \t'.contains(ch)) return 1;
    return 0;
  }

  void flush() {
    if (cur.isNotEmpty) {
      final s = String.fromCharCodes(cur).trim();
      if (s.isNotEmpty) chunks.add(s);
      cur = <int>[];
    }
  }

  for (var i = 0; i < runes.length; i++) {
    cur.add(runes[i]);
    if (cur.length >= cr) {
      var bestIdx = -1;
      var bestPrio = 0;
      var limit = runes.length;
      final maxLookahead = hm - cr;
      if (i + 1 + maxLookahead < limit) limit = i + 1 + maxLookahead;
      for (var j = i + 1; j < limit; j++) {
        final p = isBreak(runes[j]);
        if (p > bestPrio) {
          bestPrio = p;
          bestIdx = j;
        }
        if (p == 3) break;
      }
      if (bestIdx >= 0) {
        for (var k = i + 1; k <= bestIdx; k++) {
          cur.add(runes[k]);
        }
        flush();
        i = bestIdx;
        continue;
      }
      if (cur.length >= hm) flush();
    }
  }
  flush();
  return chunks;
}
