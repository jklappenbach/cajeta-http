import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

/** java.net.http load client: Client get <url> <total> <conns> <keepalive>. */
public final class Client {
    public static void main(String[] args) throws Exception {
        if (args.length != 5 || !args[0].equals("get")) {
            System.err.println("usage: Client get <url> <total> <conns> <keepalive>");
            System.exit(2);
        }
        URI uri = URI.create(args[1]);
        long total = Long.parseLong(args[2]);
        int conns = Integer.parseInt(args[3]);
        boolean keepAlive = !args[4].equals("0");
        if (conns < 1 || total < 0) { System.err.println("bad total/conns"); System.exit(2); }
        byte[] expect = "Hello, World!".getBytes();

        ExecutorService exec = Executors.newFixedThreadPool(conns);
        HttpClient client = HttpClient.newBuilder()
                .version(HttpClient.Version.HTTP_1_1)
                .executor(exec)
                .build();
        HttpRequest.Builder rb = HttpRequest.newBuilder(uri).GET();
        // keepalive=0: needs -Djdk.httpclient.allowRestrictedHeaders=connection (run-client.sh sets it).
        if (!keepAlive) rb.header("Connection", "close");
        HttpRequest req = rb.build();

        AtomicLong responses = new AtomicLong(), errors = new AtomicLong();
        CountDownLatch start = new CountDownLatch(1);
        Thread[] workers = new Thread[conns];
        for (int w = 0; w < conns; w++) {
            long mine = total / conns + (w < total % conns ? 1 : 0);
            workers[w] = Thread.ofPlatform().unstarted(() -> {
                try { start.await(); } catch (InterruptedException e) { return; }
                long got = 0, bad = 0;
                for (long i = 0; i < mine; i++) {
                    try {
                        HttpResponse<byte[]> r = client.send(req, HttpResponse.BodyHandlers.ofByteArray());
                        got++;
                        if (r.statusCode() != 200 || !Arrays.equals(r.body(), expect)) bad++;
                    } catch (Exception e) {
                        bad++;
                    }
                }
                responses.addAndGet(got);
                errors.addAndGet(bad);
            });
            workers[w].start();
        }
        long t0 = System.nanoTime();
        start.countDown();
        for (Thread t : workers) t.join();
        long elapsed = System.nanoTime() - t0;
        // "requests" = completed responses (incl. wrong status/body); exceptions count only as errors.
        System.out.println("{\"requests\":" + responses.get() + ",\"errors\":" + errors.get() + ",\"elapsed_ns\":" + elapsed + "}");
        System.out.flush();
        System.exit(0);
    }
}
