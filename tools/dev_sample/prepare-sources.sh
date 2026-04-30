#!/usr/bin/env sh
set -eu

. "$(dirname "$0")/env.sh"

product_root="$A2O_DEV_SAMPLE_ROOT/reference-products/java-spring-multi-module"
sources_root="$A2O_DEV_SAMPLE_ROOT/.work/a2o-dev-sample/sources"
app_source="$sources_root/web-app"
lib_source="$sources_root/utility-lib"
docs_source="$sources_root/docs"

chmod -R u+rwX "$sources_root" 2>/dev/null || true
rm -rf "$sources_root"
mkdir -p "$sources_root"

copy_module() {
  src="$1"
  dest="$2"
  mkdir -p "$dest"
  rsync -a --delete \
    --exclude .git \
    --exclude target \
    "$src"/ "$dest"/
}

write_lib_pom() {
  cat > "$lib_source/pom.xml" <<'XML'
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.3.7</version>
    <relativePath/>
  </parent>

  <groupId>dev.a2o.reference</groupId>
  <artifactId>utility-lib</artifactId>
  <version>0.1.0-SNAPSHOT</version>
  <packaging>jar</packaging>

  <name>A2O Reference Utility Library</name>

  <properties>
    <java.version>17</java.version>
  </properties>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>
</project>
XML
}

write_app_pom() {
  cat > "$app_source/pom.xml" <<'XML'
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.3.7</version>
    <relativePath/>
  </parent>

  <groupId>dev.a2o.reference</groupId>
  <artifactId>web-app</artifactId>
  <version>0.1.0-SNAPSHOT</version>
  <packaging>jar</packaging>

  <name>A2O Reference Spring Web App</name>

  <properties>
    <java.version>17</java.version>
  </properties>

  <dependencies>
    <dependency>
      <groupId>dev.a2o.reference</groupId>
      <artifactId>utility-lib</artifactId>
      <version>${project.version}</version>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
XML
}

init_repo() {
  repo="$1"
  git -C "$repo" init -q
  git -C "$repo" config user.name "A2O Dev Sample"
  git -C "$repo" config user.email "a2o-dev-sample@example.invalid"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "Initial Java reference module"
  git -C "$repo" branch -f a2o/dev-sample-live HEAD
}

copy_module "$product_root/utility-lib" "$lib_source"
copy_module "$product_root/web-app" "$app_source"
copy_module "$product_root/docs" "$docs_source"
write_lib_pom
write_app_pom
init_repo "$lib_source"
init_repo "$app_source"
init_repo "$docs_source"

echo "dev_sample_app_source=$app_source"
echo "dev_sample_lib_source=$lib_source"
echo "dev_sample_docs_source=$docs_source"
