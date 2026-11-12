# WorkManager (pulled in by ultralytics_yolo) creates its Room database by reflection;
# without these rules R8 strips the generated class and the app crashes at startup.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
