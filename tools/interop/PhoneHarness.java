import java.io.*;
import java.lang.reflect.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import com.tiger.usbmanager.auth.UsbAuthDaemon;

// Runs the production phone protocol on a desktop JVM, without Android or USB.
public class PhoneHarness {
    public static void main(String[] args) throws Exception {
        if (args[0].equals("descriptors")) {
            Method method = UsbAuthDaemon.class.getDeclaredMethod("descriptors");
            method.setAccessible(true);
            byte[] bytes = (byte[])method.invoke(null);
            ByteBuffer b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
            if (b.getInt(4) != bytes.length) throw new AssertionError("descriptor total length");
            b.position(28 + 23 + 23 + 35 + 35); // header, FS, HS, SS, OS compatible ID
            b.get(); int blockLength = b.getInt(); b.getShort();
            if (b.getShort() != 5 || b.getShort() != 1) throw new AssertionError("OS property header");
            int size = b.getInt();
            if (b.getInt() != 1) throw new AssertionError("REG_SZ");
            byte[] name = new byte[Short.toUnsignedInt(b.getShort())]; b.get(name);
            byte[] value = new byte[b.getInt()]; b.get(value);
            // Kernel utf8s_to_utf16s stops at the first NUL. This catches the
            // previous double-UTF16 conversion that produced D={ in Windows.
            String n = new String(name, StandardCharsets.UTF_8).split("\0", -1)[0];
            String v = new String(value, StandardCharsets.UTF_8).split("\0", -1)[0];
            if (!n.equals("DeviceInterfaceGUID") || !v.equals(UsbAuthDaemon.INTERFACE_GUID))
                throw new AssertionError("kernel-converted GUID property: " + n + "=" + v);
            if (size != 14 + name.length + value.length || blockLength != size + 11 || b.hasRemaining())
                throw new AssertionError("OS descriptor lengths");
            System.out.println("PASS FunctionFS property encoding and lengths"); return;
        }
        Class<?> cls = Class.forName("com.tiger.usbmanager.auth.UsbAuthDaemon$Session");
        Constructor<?> ctor = cls.getDeclaredConstructor(Path.class, Path.class, boolean.class, String.class);
        ctor.setAccessible(true);
        Object session = ctor.newInstance(Paths.get(args[0]), Paths.get(args[1]), Boolean.parseBoolean(args[2]), ",mtp,false");
        Method handle = cls.getDeclaredMethod("handle", String.class); handle.setAccessible(true);
        Method sent = cls.getDeclaredMethod("responseSent"); sent.setAccessible(true);
        BufferedReader input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        for (String line; (line = input.readLine()) != null;) {
            Object response = handle.invoke(session, line);
            sent.invoke(session);
            System.out.println(response); System.out.flush();
        }
    }
}
